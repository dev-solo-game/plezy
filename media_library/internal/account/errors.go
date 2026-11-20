package account

import (
	"errors"
	"fmt"
)

var (
	ErrUnauthorized         = errors.New("unauthorized")
	ErrForbidden            = errors.New("forbidden")
	ErrInvalidCredentials   = errors.New("invalid credentials")
	ErrRateLimited          = errors.New("rate limited")
	ErrRegistrationClosed   = errors.New("registration is closed")
	ErrInvalidInvite        = errors.New("invalid or expired invite code")
	ErrInvalidInput         = errors.New("invalid input")
	ErrNotFound             = errors.New("not found")
	ErrConflict             = errors.New("conflict")
	ErrAccountDisabled      = errors.New("account is disabled")
	ErrAccountPendingDelete = errors.New("account is pending deletion")
)

// RateLimitError carries the Retry-After hint in seconds while matching ErrRateLimited via errors.Is.
type RateLimitError struct {
	RetryAfterSec int
}

func (e *RateLimitError) Error() string {
	return fmt.Sprintf("%s: retry after %ds", ErrRateLimited.Error(), e.RetryAfterSec)
}

func (e *RateLimitError) Unwrap() error {
	return ErrRateLimited
}
