package ingest

import (
	"errors"
	"fmt"
)

var (
	ErrUnauthorized       = errors.New("unauthorized")
	ErrForbidden          = errors.New("forbidden")
	ErrNotFound           = errors.New("not found")
	ErrInvalidInput       = errors.New("invalid input")
	ErrConflict           = errors.New("conflict")
	ErrSourceDeleted      = errors.New("source has been deleted")
	ErrFullScanNotAllowed = errors.New("full scan is not allowed on this device")
	ErrScanNotAllowed     = errors.New("scanning is not allowed on this device")
	ErrSessionNotRunning  = errors.New("scan session is no longer running")
)

// QuotaExceededError reports a per-household rate or capacity limit violation (G9).
type QuotaExceededError struct {
	Quota   string
	Limit   int64
	Current int64
}

func (e *QuotaExceededError) Error() string {
	return fmt.Sprintf("quota exceeded for %s (%d/%d)", e.Quota, e.Current, e.Limit)
}
