package api

import (
	"crypto/sha256"
	"encoding/hex"
	"os"
	"path/filepath"
	"time"
)

// Mount artwork (posters/fanart sitting next to media on SMB/WebDAV/Quark) used
// to be re-downloaded from the storage backend on every request. Remote mounts
// are cached on disk under <data>/artwork_cache/mount; local disks are read
// directly since they are already fast.
const localArtworkCacheTTL = 7 * 24 * time.Hour

func (s *Server) localArtworkCachePath(mountID, path string) string {
	sum := sha256.Sum256([]byte(mountID + "\x00" + path))
	h := hex.EncodeToString(sum[:])
	return filepath.Join(s.Store.DataDir(), "artwork_cache", "mount", h[:2], h)
}

func (s *Server) readLocalArtworkCache(mountID, path string) ([]byte, bool) {
	p := s.localArtworkCachePath(mountID, path)
	info, err := os.Stat(p)
	if err != nil || info.Size() == 0 || time.Since(info.ModTime()) > localArtworkCacheTTL {
		return nil, false
	}
	data, err := os.ReadFile(p)
	if err != nil || len(data) == 0 {
		return nil, false
	}
	return data, true
}

func (s *Server) writeLocalArtworkCache(mountID, path string, data []byte) {
	p := s.localArtworkCachePath(mountID, path)
	if err := os.MkdirAll(filepath.Dir(p), 0o755); err != nil {
		return
	}
	tmp := p + ".tmp"
	if err := os.WriteFile(tmp, data, 0o644); err != nil {
		return
	}
	if err := os.Rename(tmp, p); err != nil {
		_ = os.Remove(tmp)
	}
}
