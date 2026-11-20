package source

import (
	"errors"
	"fmt"
	"strings"
)

var (
	ErrUnauthorized           = errors.New("unauthorized")
	ErrForbidden              = errors.New("forbidden")
	ErrNotFound               = errors.New("not found")
	ErrInvalidInput           = errors.New("invalid input")
	ErrConflict               = errors.New("conflict")
	ErrSourceDeleted          = errors.New("source has been deleted")
	ErrKindNotAllowedOnDevice = errors.New("source kind is not allowed on this device")
	ErrIdentityMismatch       = errors.New("source identity does not match existing source")
)

type KindNotAllowedError struct {
	DeviceClass    string
	Kind           string
	AllowedDevices []string
}

func (e *KindNotAllowedError) Error() string {
	return fmt.Sprintf("%s: kind=%q device_class=%q allowed_devices=[%s]",
		ErrKindNotAllowedOnDevice.Error(), e.Kind, e.DeviceClass, strings.Join(e.AllowedDevices, ","))
}

func (e *KindNotAllowedError) Unwrap() error {
	return ErrKindNotAllowedOnDevice
}

type DuplicateSourceError struct {
	ExistingSourceID string
}

func (e *DuplicateSourceError) Error() string {
	return fmt.Sprintf("%s: source already exists (%s)", ErrConflict.Error(), e.ExistingSourceID)
}

func (e *DuplicateSourceError) Unwrap() error {
	return ErrConflict
}

type SimilarSourceRef struct {
	ID        string `json:"id"`
	Name      string `json:"name"`
	CreatedAt int64  `json:"created_at"`
}

type SimilarSourceError struct {
	SimilarSources []SimilarSourceRef
}

func (e *SimilarSourceError) Error() string {
	return fmt.Sprintf("%s: similar source already exists (%d)", ErrConflict.Error(), len(e.SimilarSources))
}

func (e *SimilarSourceError) Unwrap() error {
	return ErrConflict
}

type QuotaExceededError struct {
	Quota   string
	Limit   int
	Current int
}

func (e *QuotaExceededError) Error() string {
	return fmt.Sprintf("quota exceeded for %s (%d/%d)", e.Quota, e.Current, e.Limit)
}

type CredentialConflictError struct {
	Current Credential
}

func (e *CredentialConflictError) Error() string {
	return fmt.Sprintf("%s: credential version conflict (current=%d)", ErrConflict.Error(), e.Current.Version)
}

func (e *CredentialConflictError) Unwrap() error {
	return ErrConflict
}
