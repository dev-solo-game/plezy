package security

import (
	"sync"
	"time"
)

const (
	DefaultMaxLoginFailures = 5
	DefaultFailureWindow    = 5 * time.Minute
	DefaultLockoutDuration  = 15 * time.Minute
)

type lockoutEntry struct {
	failures    int
	windowStart time.Time
	lockedUntil time.Time
}

type windowEntry struct {
	count       int
	windowStart time.Time
}

type LoginLimiter struct {
	mu      sync.Mutex
	nowFn   func() time.Time
	lockout map[string]*lockoutEntry
	windows map[string]*windowEntry
}

func NewLoginLimiter() *LoginLimiter {
	return &LoginLimiter{
		nowFn:   time.Now,
		lockout: make(map[string]*lockoutEntry),
		windows: make(map[string]*windowEntry),
	}
}

func (l *LoginLimiter) SetClock(fn func() time.Time) {
	l.mu.Lock()
	defer l.mu.Unlock()
	if fn != nil {
		l.nowFn = fn
	}
}

func (l *LoginLimiter) CheckLockout(key string) (locked bool, retryAfterSec int) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.nowFn()
	e, ok := l.lockout[key]
	if !ok {
		return false, 0
	}
	if !e.lockedUntil.IsZero() && now.Before(e.lockedUntil) {
		secs := int(e.lockedUntil.Sub(now).Seconds())
		if secs < 1 {
			secs = 1
		}
		return true, secs
	}
	if !e.lockedUntil.IsZero() && !now.Before(e.lockedUntil) {
		delete(l.lockout, key)
	}
	return false, 0
}

func (l *LoginLimiter) RecordFailure(key string) {
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.nowFn()
	if len(l.lockout) > 4096 {
		for k, v := range l.lockout {
			if (v.lockedUntil.IsZero() || !now.Before(v.lockedUntil)) && now.Sub(v.windowStart) >= DefaultFailureWindow {
				delete(l.lockout, k)
			}
		}
	}
	e, ok := l.lockout[key]
	if !ok || (!e.lockedUntil.IsZero() && !now.Before(e.lockedUntil)) || now.Sub(e.windowStart) >= DefaultFailureWindow {
		e = &lockoutEntry{windowStart: now}
		l.lockout[key] = e
	}
	if !e.lockedUntil.IsZero() && now.Before(e.lockedUntil) {
		return
	}
	e.failures++
	if e.failures >= DefaultMaxLoginFailures {
		e.lockedUntil = now.Add(DefaultLockoutDuration)
	}
}

func (l *LoginLimiter) RecordSuccess(key string) {
	l.mu.Lock()
	delete(l.lockout, key)
	l.mu.Unlock()
}

func (l *LoginLimiter) AllowWindow(key string, limit int, window time.Duration) bool {
	if limit <= 0 || window <= 0 {
		return true
	}
	l.mu.Lock()
	defer l.mu.Unlock()
	now := l.nowFn()
	if len(l.windows) > 4096 {
		for k, v := range l.windows {
			if now.Sub(v.windowStart) >= window {
				delete(l.windows, k)
			}
		}
	}
	e, ok := l.windows[key]
	if !ok || now.Sub(e.windowStart) >= window {
		l.windows[key] = &windowEntry{count: 1, windowStart: now}
		return true
	}
	if e.count >= limit {
		return false
	}
	e.count++
	return true
}
