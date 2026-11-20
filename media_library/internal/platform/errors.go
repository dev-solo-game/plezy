package platform

import (
	"errors"
	"fmt"
)

var (
	ErrUnauthorized           = errors.New("unauthorized")
	ErrInvalidCredentials     = errors.New("invalid username or password")
	ErrRateLimited            = errors.New("too many attempts, please try again later")
	ErrPasswordChangeRequired = errors.New("password change required")
	ErrForbiddenIP            = errors.New("admin access forbidden from this IP")
	ErrInvalidInput           = errors.New("invalid input")
	ErrNotFound               = errors.New("not found")
	ErrConflict               = errors.New("conflict")
)

type RateLimitError struct {
	RetryAfterSec int
}

func (e *RateLimitError) Error() string {
	return fmt.Sprintf("%s (retry after %ds)", ErrRateLimited.Error(), e.RetryAfterSec)
}

func (e *RateLimitError) Unwrap() error {
	return ErrRateLimited
}
