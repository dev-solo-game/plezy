package ingest

import (
	"bytes"
	"context"
	"crypto/sha256"
	"database/sql"
	"encoding/hex"
	"errors"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"unicode/utf8"

	"plezy/media_library/internal/account"
)

var reSHA256 = regexp.MustCompile(`^[0-9a-f]{64}$`)

func normalizeSHA256(raw string) (string, error) {
	cleaned := strings.ToLower(strings.TrimSpace(raw))
	cleaned = strings.TrimPrefix(cleaned, "sha256:")
	if !reSHA256.MatchString(cleaned) {
		return "", fmt.Errorf("%w: invalid sha256 digest", ErrInvalidInput)
	}
	return cleaned, nil
}

func classifyAndValidateSidecar(kindHint, contentType string, data []byte) (kind, normalizedMIME string, err error) {
	if len(data) == 0 {
		return "", "", fmt.Errorf("%w: sidecar payload cannot be empty", ErrInvalidInput)
	}

	ct := strings.ToLower(strings.TrimSpace(strings.SplitN(contentType, ";", 2)[0]))
	detected := http.DetectContentType(data)
	kh := strings.ToLower(strings.TrimSpace(kindHint))

	isArtwork := kh == SidecarKindArtwork ||
		strings.HasPrefix(ct, "image/") ||
		strings.HasPrefix(detected, "image/")

	if isArtwork {
		if len(data) > MaxArtworkSidecarBytes {
			return "", "", fmt.Errorf("%w: artwork sidecar exceeds %d bytes", ErrInvalidInput, MaxArtworkSidecarBytes)
		}
		mimeType := detected
		switch mimeType {
		case "image/jpeg", "image/png", "image/webp":
		default:
			if ct == "image/jpeg" || ct == "image/png" || ct == "image/webp" {
				mimeType = ct
			} else {
				return "", "", fmt.Errorf("%w: unsupported artwork image type %q", ErrInvalidInput, detected)
			}
		}
		return SidecarKindArtwork, mimeType, nil
	}

	if kh != "" && kh != SidecarKindNfo {
		return "", "", fmt.Errorf("%w: unsupported sidecar kind %q", ErrInvalidInput, kindHint)
	}
	if len(data) > MaxNfoSidecarBytes {
		return "", "", fmt.Errorf("%w: nfo sidecar exceeds %d bytes", ErrInvalidInput, MaxNfoSidecarBytes)
	}
	if !utf8.Valid(data) || bytes.IndexByte(data, 0) >= 0 {
		return "", "", fmt.Errorf("%w: nfo sidecar must be valid UTF-8 text", ErrInvalidInput)
	}
	return SidecarKindNfo, "text/xml; charset=utf-8", nil
}

func (s *Service) SidecarExists(p *account.Principal, sha256Hex string) (bool, error) {
	if p == nil {
		return false, ErrUnauthorized
	}
	digest, err := normalizeSHA256(sha256Hex)
	if err != nil {
		return false, err
	}
	var cnt int
	if err := s.store.ReadDB().QueryRow(`
		SELECT COUNT(*) FROM sidecars WHERE household_id = ? AND sha256 = ?`,
		p.HouseholdID, digest,
	).Scan(&cnt); err != nil {
		return false, err
	}
	return cnt > 0, nil
}

func (s *Service) PutSidecar(p *account.Principal, sha256Hex, kindHint, contentType string, data []byte) error {
	if p == nil {
		return ErrUnauthorized
	}
	if !p.HasPerm(account.PermUploadFacts) {
		return ErrForbidden
	}
	digest, err := normalizeSHA256(sha256Hex)
	if err != nil {
		return err
	}
	kind, normMIME, err := classifyAndValidateSidecar(kindHint, contentType, data)
	if err != nil {
		return err
	}

	actualSum := sha256.Sum256(data)
	actualHex := hex.EncodeToString(actualSum[:])
	if actualHex != digest {
		return fmt.Errorf("%w: sha256 mismatch", ErrInvalidInput)
	}

	// Fast idempotency check
	exists, err := s.SidecarExists(p, digest)
	if err != nil {
		return err
	}
	if exists {
		return nil
	}

	var maxBytes, curBytes int64
	if err := s.store.ReadDB().QueryRow(`SELECT quota_max_sidecar_bytes FROM households WHERE id = ?`, p.HouseholdID).Scan(&maxBytes); err != nil {
		return err
	}
	if err := s.store.ReadDB().QueryRow(`SELECT COALESCE(SUM(size_bytes), 0) FROM sidecars WHERE household_id = ?`, p.HouseholdID).Scan(&curBytes); err != nil {
		return err
	}
	if curBytes+int64(len(data)) > maxBytes {
		return &QuotaExceededError{
			Quota:   "sidecar_bytes",
			Limit:   maxBytes,
			Current: curBytes,
		}
	}

	relPath := filepath.Join(digest[:2], digest)
	baseDir := filepath.Join(s.store.DataDir(), "sidecars", p.HouseholdID)
	fullPath := filepath.Join(baseDir, relPath)
	if err := os.MkdirAll(filepath.Dir(fullPath), 0o755); err != nil {
		return err
	}

	tmpFile, err := os.CreateTemp(filepath.Dir(fullPath), digest+".tmp.*")
	if err != nil {
		return err
	}
	tmpPath := tmpFile.Name()
	if _, err := tmpFile.Write(data); err != nil {
		_ = tmpFile.Close()
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmpFile.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, fullPath); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}

	nowMs := s.nowFn().UnixMilli()
	tx, err := s.store.DB().Begin()
	if err != nil {
		return err
	}
	defer func() { _ = tx.Rollback() }()

	// Re-check quota inside write tx to prevent concurrent races.
	var already int
	if err := tx.QueryRow(`SELECT COUNT(*) FROM sidecars WHERE household_id = ? AND sha256 = ?`, p.HouseholdID, digest).Scan(&already); err != nil {
		return err
	}
	if already > 0 {
		return tx.Commit()
	}
	if err := tx.QueryRow(`SELECT COALESCE(SUM(size_bytes), 0) FROM sidecars WHERE household_id = ?`, p.HouseholdID).Scan(&curBytes); err != nil {
		return err
	}
	if curBytes+int64(len(data)) > maxBytes {
		return &QuotaExceededError{
			Quota:   "sidecar_bytes",
			Limit:   maxBytes,
			Current: curBytes,
		}
	}

	if _, err := tx.Exec(`
		INSERT INTO sidecars(household_id, sha256, kind, content_type, size_bytes, storage_path, created_at)
		VALUES (?, ?, ?, ?, ?, ?, ?)`,
		p.HouseholdID, digest, kind, normMIME, len(data), filepath.ToSlash(relPath), nowMs,
	); err != nil {
		return err
	}
	return tx.Commit()
}

// ReadBytes retrieves a stored sidecar file scoped strictly to householdID.
func (s *Service) ReadBytes(householdID, sha256Hex string) ([]byte, string, error) {
	hhID := strings.TrimSpace(householdID)
	if hhID == "" {
		return nil, "", ErrUnauthorized
	}
	digest, err := normalizeSHA256(sha256Hex)
	if err != nil {
		return nil, "", err
	}

	var relPath, contentType string
	err = s.store.ReadDB().QueryRow(`
		SELECT storage_path, content_type
		FROM sidecars
		WHERE household_id = ? AND sha256 = ?`,
		hhID, digest,
	).Scan(&relPath, &contentType)
	if errors.Is(err, sql.ErrNoRows) {
		return nil, "", ErrNotFound
	}
	if err != nil {
		return nil, "", err
	}

	baseDir := filepath.Clean(filepath.Join(s.store.DataDir(), "sidecars", hhID))
	fullPath := filepath.Clean(filepath.Join(baseDir, filepath.FromSlash(relPath)))
	if fullPath != baseDir && !strings.HasPrefix(fullPath, baseDir+string(os.PathSeparator)) {
		return nil, "", ErrNotFound
	}
	data, err := os.ReadFile(fullPath)
	if err != nil {
		return nil, "", err
	}
	return data, contentType, nil
}

// ReadText implements library.SidecarReader for the S4 scraper.
func (s *Service) ReadText(_ context.Context, householdID, sha256Hex string) (string, error) {
	data, _, err := s.ReadBytes(householdID, sha256Hex)
	if err != nil {
		return "", err
	}
	return string(data), nil
}
