package source

import (
	"strings"
	"time"

	"plezy/media_library/internal/db"
)

const (
	StatusActive  = "active"
	StatusDeleted = "deleted"

	CredStatusValid   = "valid"
	CredStatusExpired = "expired"
	CredStatusKicked  = "kicked"

	CredUpdateModeRefresh = "refresh"
	CredUpdateModeReplace = "replace"

	SourceDeletionRetention = 30 * 24 * time.Hour
	MaxCredentialBytes      = 64 * 1024
)

type SourceView struct {
	ID              string          `json:"id"`
	HouseholdID     string          `json:"household_id"`
	Kind            string          `json:"kind"`
	Name            string          `json:"name"`
	IdentityKey     string          `json:"identity_key"`
	IdentityUnique  bool            `json:"identity_unique"`
	CreatedByMember string          `json:"created_by_member"`
	CreatedByDevice string          `json:"created_by_device"`
	Status          string          `json:"status"`
	CreatedAt       int64           `json:"created_at"`
	UpdatedAt       int64           `json:"updated_at"`
	CredentialMeta  *CredentialMeta `json:"credential_meta,omitempty"`
	ScanState       *ScanState      `json:"scan_state,omitempty"`
	Folders         []FolderView    `json:"folders,omitempty"`
}

type CredentialMeta struct {
	Version         int    `json:"version"`
	KeyEpoch        int    `json:"key_epoch"`
	Status          string `json:"status"`
	UpdatedByDevice string `json:"updated_by_device"`
	UpdatedAt       int64  `json:"updated_at"`
}

type Credential struct {
	SourceID        string `json:"source_id"`
	HouseholdID     string `json:"household_id"`
	Ciphertext      string `json:"ciphertext"`
	Version         int    `json:"version"`
	KeyEpoch        int    `json:"key_epoch"`
	Status          string `json:"status"`
	UpdatedByDevice string `json:"updated_by_device"`
	UpdatedAt       int64  `json:"updated_at"`
}

type ScanState struct {
	IncrementalWatermark int64  `json:"incremental_watermark"`
	LastFullScanAt       *int64 `json:"last_full_scan_at,omitempty"`
	LastScanResult       string `json:"last_scan_result"`
	UpdatedAt            int64  `json:"updated_at"`
}

type FolderView struct {
	ID           string   `json:"id"`
	HouseholdID  string   `json:"household_id"`
	SourceID     string   `json:"source_id"`
	Path         string   `json:"path"`
	ExcludePaths []string `json:"exclude_paths"`
	LibraryHint  string   `json:"library_hint"`
	BaselineAt   *int64   `json:"baseline_at,omitempty"`
	CreatedAt    int64    `json:"created_at"`
	UpdatedAt    int64    `json:"updated_at"`
}

type CreateSourceRequest struct {
	Kind             string        `json:"kind"`
	Name             string        `json:"name"`
	IdentityKey      string        `json:"identity_key"`
	Ciphertext       string        `json:"ciphertext"`
	KeyEpoch         int           `json:"key_epoch,omitempty"`
	ConfirmDuplicate bool          `json:"confirm_duplicate,omitempty"`
	Folders          []FolderInput `json:"folders,omitempty"`
}

type UpdateSourceRequest struct {
	Name *string `json:"name,omitempty"`
}

type FolderInput struct {
	Path         string   `json:"path"`
	ExcludePaths []string `json:"exclude_paths,omitempty"`
	LibraryHint  string   `json:"library_hint,omitempty"`
}

type UpdateFolderRequest struct {
	Path         *string   `json:"path,omitempty"`
	ExcludePaths *[]string `json:"exclude_paths,omitempty"`
	LibraryHint  *string   `json:"library_hint,omitempty"`
}

type UpdateCredentialRequest struct {
	BaseVersion int    `json:"base_version"`
	Ciphertext  string `json:"ciphertext"`
	KeyEpoch    int    `json:"key_epoch,omitempty"`
	Mode        string `json:"mode,omitempty"`
	IdentityKey string `json:"identity_key,omitempty"`
}

type ReportCredentialStatusRequest struct {
	Status  string `json:"status"`
	Version int    `json:"version,omitempty"`
}

func IsValidKind(kind string) bool {
	switch strings.TrimSpace(kind) {
	case db.SourceKindQuark, db.SourceKindWebDAV, db.SourceKindEmby, db.SourceKindJellyfin:
		return true
	default:
		return false
	}
}

func KindHasFoldersAndScan(kind string) bool {
	switch strings.TrimSpace(kind) {
	case db.SourceKindQuark, db.SourceKindWebDAV:
		return true
	default:
		return false
	}
}

func KindHasUniqueIdentity(kind string) bool {
	switch strings.TrimSpace(kind) {
	case db.SourceKindQuark, db.SourceKindEmby, db.SourceKindJellyfin:
		return true
	default:
		return false
	}
}

func IsValidLibraryHint(hint string) bool {
	switch strings.TrimSpace(hint) {
	case "auto", "movie", "show", "anime", "variety", "documentary":
		return true
	default:
		return false
	}
}
