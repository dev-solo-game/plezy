package identify

import (
	"context"
	"database/sql"
	"errors"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"plezy/media_library/internal/applog"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/library"
	"plezy/media_library/internal/metadata"
)

type Queue struct {
	store   *db.Store
	scraper *library.Scraper
	hub     *events.Hub

	workers      int
	pollInterval time.Duration
	baseBackoff  time.Duration
	maxAttempts  int
	nowFn        func() time.Time

	paused atomic.Bool

	claimMu     sync.Mutex
	lastHouseID string

	wakeCh chan struct{}

	mu      sync.Mutex
	started bool
	cancel  context.CancelFunc
	wg      sync.WaitGroup
}

type QueueJob struct {
	ID          int64
	HouseholdID string
	GroupKey    string
	Reason      string
	Attempts    int
}

type HouseholdQueueStats struct {
	HouseholdID   string `json:"household_id"`
	Queued        int    `json:"queued"`
	Processing    int    `json:"processing"`
	Done          int    `json:"done"`
	Failed        int    `json:"failed"`
	LastErrorCode string `json:"last_error_code,omitempty"`
}

type QueueStats struct {
	Paused       bool                  `json:"paused"`
	Workers      int                   `json:"workers"`
	Queued       int                   `json:"queued"`
	Processing   int                   `json:"processing"`
	Done         int                   `json:"done"`
	Failed       int                   `json:"failed"`
	ByHousehold  []HouseholdQueueStats `json:"by_household"`
}

type Option func(*Queue)

func WithWorkers(n int) Option {
	return func(q *Queue) {
		if n > 0 {
			q.workers = n
		}
	}
}

func WithPollInterval(d time.Duration) Option {
	return func(q *Queue) {
		if d > 0 {
			q.pollInterval = d
		}
	}
}

func WithBaseBackoff(d time.Duration) Option {
	return func(q *Queue) {
		if d > 0 {
			q.baseBackoff = d
		}
	}
}

func WithMaxAttempts(n int) Option {
	return func(q *Queue) {
		if n > 0 {
			q.maxAttempts = n
		}
	}
}

func WithClock(fn func() time.Time) Option {
	return func(q *Queue) {
		if fn != nil {
			q.nowFn = fn
		}
	}
}

func NewQueue(store *db.Store, scraper *library.Scraper, hub *events.Hub, opts ...Option) *Queue {
	q := &Queue{
		store:        store,
		scraper:      scraper,
		hub:          hub,
		workers:      4,
		pollInterval: 2 * time.Second,
		baseBackoff:  5 * time.Second,
		maxAttempts:  5,
		nowFn:        time.Now,
		wakeCh:       make(chan struct{}, 1),
	}
	for _, opt := range opts {
		if opt != nil {
			opt(q)
		}
	}
	return q
}

func (q *Queue) Start() {
	q.mu.Lock()
	defer q.mu.Unlock()
	if q.started {
		return
	}
	q.ResetStaleProcessing()

	ctx, cancel := context.WithCancel(context.Background())
	q.cancel = cancel
	q.started = true

	for i := 0; i < q.workers; i++ {
		q.wg.Add(1)
		go q.workerLoop(ctx)
	}
}

func (q *Queue) Stop() {
	q.mu.Lock()
	if !q.started {
		q.mu.Unlock()
		return
	}
	cancel := q.cancel
	q.started = false
	q.cancel = nil
	q.mu.Unlock()

	if cancel != nil {
		cancel()
	}
	q.wg.Wait()
}

func (q *Queue) Wake() {
	select {
	case q.wakeCh <- struct{}{}:
	default:
	}
}

func (q *Queue) Pause() {
	q.paused.Store(true)
}

func (q *Queue) Resume() {
	q.paused.Store(false)
	q.Wake()
}

func (q *Queue) IsPaused() bool {
	return q.paused.Load()
}

// ResetStaleProcessing resets any leftover 'processing' rows back to 'queued' on startup.
func (q *Queue) ResetStaleProcessing() int64 {
	if q == nil || q.store == nil {
		return 0
	}
	nowMs := q.nowFn().UnixMilli()
	res, err := q.store.DB().Exec(`
		UPDATE identify_queue
		SET status = 'queued', updated_at = ?
		WHERE status = 'processing'`,
		nowMs,
	)
	if err != nil {
		return 0
	}
	n, _ := res.RowsAffected()
	return n
}

func (q *Queue) Enqueue(householdID, groupKey, reason string, delay time.Duration) error {
	if householdID == "" || groupKey == "" {
		return nil
	}
	if reason == "" {
		reason = "changed"
	}
	nowMs := q.nowFn().UnixMilli()
	notBefore := nowMs + delay.Milliseconds()
	_, err := q.store.DB().Exec(`
		INSERT INTO identify_queue(
			household_id, group_key, reason, status, not_before, attempts, last_error_code, created_at, updated_at
		) VALUES (?, ?, ?, 'queued', ?, 0, '', ?, ?)
		ON CONFLICT(household_id, group_key) DO UPDATE SET
			reason          = CASE WHEN identify_queue.reason = 'new' THEN 'new' ELSE excluded.reason END,
			status          = 'queued',
			not_before      = excluded.not_before,
			attempts        = 0,
			last_error_code = '',
			updated_at      = excluded.updated_at`,
		householdID, groupKey, reason, notBefore, nowMs, nowMs,
	)
	if err == nil {
		q.Wake()
	}
	return err
}

func (q *Queue) RetryFailed(householdID string) (int64, error) {
	nowMs := q.nowFn().UnixMilli()
	var (
		res sql.Result
		err error
	)
	if strings.TrimSpace(householdID) == "" {
		res, err = q.store.DB().Exec(`
			UPDATE identify_queue
			SET status = 'queued', not_before = ?, attempts = 0, last_error_code = '', updated_at = ?
			WHERE status = 'failed'`,
			nowMs, nowMs,
		)
	} else {
		res, err = q.store.DB().Exec(`
			UPDATE identify_queue
			SET status = 'queued', not_before = ?, attempts = 0, last_error_code = '', updated_at = ?
			WHERE household_id = ? AND status = 'failed'`,
			nowMs, nowMs, householdID,
		)
	}
	if err != nil {
		return 0, err
	}
	n, _ := res.RowsAffected()
	if n > 0 {
		q.Wake()
	}
	return n, nil
}

// Stats returns privacy-safe aggregate identify_queue counters for D8 admin observability
// and queue monitoring (never exposing group_key, file paths, or work titles).
func (q *Queue) Stats() (QueueStats, error) {
	out := QueueStats{
		Paused:      q.paused.Load(),
		Workers:     q.workers,
		ByHousehold: make([]HouseholdQueueStats, 0),
	}
	rows, err := q.store.ReadDB().Query(`
		SELECT household_id, status, COUNT(*), MAX(last_error_code)
		FROM identify_queue
		GROUP BY household_id, status
		ORDER BY household_id ASC`,
	)
	if err != nil {
		return out, err
	}
	defer rows.Close()

	hhMap := make(map[string]*HouseholdQueueStats)
	var hhOrder []string
	for rows.Next() {
		var hhID, st, errCode string
		var cnt int
		if err := rows.Scan(&hhID, &st, &cnt, &errCode); err != nil {
			return out, err
		}
		entry, ok := hhMap[hhID]
		if !ok {
			entry = &HouseholdQueueStats{HouseholdID: hhID}
			hhMap[hhID] = entry
			hhOrder = append(hhOrder, hhID)
		}
		switch st {
		case "queued":
			entry.Queued += cnt
			out.Queued += cnt
		case "processing":
			entry.Processing += cnt
			out.Processing += cnt
		case "done":
			entry.Done += cnt
			out.Done += cnt
		case "failed":
			entry.Failed += cnt
			out.Failed += cnt
			if errCode != "" {
				entry.LastErrorCode = errCode
			}
		}
		if entry.LastErrorCode == "" && errCode != "" {
			entry.LastErrorCode = errCode
		}
	}
	if err := rows.Err(); err != nil {
		return out, err
	}
	for _, hhID := range hhOrder {
		out.ByHousehold = append(out.ByHousehold, *hhMap[hhID])
	}
	return out, nil
}

func (q *Queue) workerLoop(ctx context.Context) {
	defer q.wg.Done()
	ticker := time.NewTicker(q.pollInterval)
	defer ticker.Stop()

	for {
		if ctx.Err() != nil {
			return
		}
		if !q.paused.Load() {
			for {
				if ctx.Err() != nil || q.paused.Load() {
					break
				}
				didWork, err := q.ProcessOne(ctx)
				if err != nil {
					applog.Warnf("identify", "识别队列调度出错: %v", err)
					break
				}
				if !didWork {
					break
				}
			}
		}

		select {
		case <-ctx.Done():
			return
		case <-q.wakeCh:
		case <-ticker.C:
		}
	}
}

// ProcessOne claims one ready job using fair per-household round-robin and executes it.
// Returns (false, nil) when no jobs are ready (or queue is paused).
func (q *Queue) ProcessOne(ctx context.Context) (bool, error) {
	if q.paused.Load() {
		return false, nil
	}
	job, found, err := q.claimNextJob()
	if err != nil || !found {
		return false, err
	}

	identErr := q.scraper.IdentifyGroup(ctx, job.HouseholdID, job.GroupKey)
	nowMs := q.nowFn().UnixMilli()
	if identErr == nil {
		if _, err := q.store.DB().Exec(`
			UPDATE identify_queue
			SET status = 'done', last_error_code = '', updated_at = ?
			WHERE id = ?`,
			nowMs, job.ID,
		); err != nil {
			return true, err
		}
		if q.hub != nil {
			q.hub.PublishToHousehold(job.HouseholdID, "library.changed", map[string]any{
				"source": "identify",
			})
		}
		return true, nil
	}

	errCode := classifyErrorCode(identErr)
	nextAttempts := job.Attempts + 1
	if nextAttempts >= q.maxAttempts {
		if _, err := q.store.DB().Exec(`
			UPDATE identify_queue
			SET status = 'failed', attempts = ?, last_error_code = ?, updated_at = ?
			WHERE id = ?`,
			nextAttempts, errCode, nowMs, job.ID,
		); err != nil {
			return true, err
		}
		_ = q.scraper.MarkGroupUnmatched(job.HouseholdID, job.GroupKey)
		applog.Warnf("identify", "识别任务达到重试上限 hh=%s job=%d attempts=%d code=%s", job.HouseholdID, job.ID, nextAttempts, errCode)
		return true, nil
	}

	backoff := q.baseBackoff << (nextAttempts - 1)
	notBefore := nowMs + backoff.Milliseconds()
	if _, err := q.store.DB().Exec(`
		UPDATE identify_queue
		SET status = 'queued', attempts = ?, not_before = ?, last_error_code = ?, updated_at = ?
		WHERE id = ?`,
		nextAttempts, notBefore, errCode, nowMs, job.ID,
	); err != nil {
		return true, err
	}
	applog.Warnf("identify", "识别任务重试排队 hh=%s job=%d attempt=%d/%d next_delay_ms=%d code=%s",
		job.HouseholdID, job.ID, nextAttempts, q.maxAttempts, backoff.Milliseconds(), errCode)
	return true, nil
}

func (q *Queue) claimNextJob() (QueueJob, bool, error) {
	q.claimMu.Lock()
	defer q.claimMu.Unlock()

	nowMs := q.nowFn().UnixMilli()
	rows, err := q.store.ReadDB().Query(`
		SELECT DISTINCT household_id
		FROM identify_queue
		WHERE status = 'queued' AND not_before <= ?
		ORDER BY household_id ASC`,
		nowMs,
	)
	if err != nil {
		return QueueJob{}, false, err
	}
	var readyHouseholds []string
	for rows.Next() {
		var hh string
		if rows.Scan(&hh) == nil && hh != "" {
			readyHouseholds = append(readyHouseholds, hh)
		}
	}
	_ = rows.Close()
	if err := rows.Err(); err != nil {
		return QueueJob{}, false, err
	}
	if len(readyHouseholds) == 0 {
		return QueueJob{}, false, nil
	}

	startIdx := 0
	if q.lastHouseID != "" {
		foundNext := false
		for i, hh := range readyHouseholds {
			if hh > q.lastHouseID {
				startIdx = i
				foundNext = true
				break
			}
		}
		if !foundNext {
			startIdx = 0
		}
	}

	for off := 0; off < len(readyHouseholds); off++ {
		hhID := readyHouseholds[(startIdx+off)%len(readyHouseholds)]
		var job QueueJob
		err := q.store.DB().QueryRow(`
			SELECT id, household_id, group_key, reason, attempts
			FROM identify_queue
			WHERE household_id = ? AND status = 'queued' AND not_before <= ?
			ORDER BY not_before ASC, id ASC
			LIMIT 1`,
			hhID, nowMs,
		).Scan(&job.ID, &job.HouseholdID, &job.GroupKey, &job.Reason, &job.Attempts)
		if errors.Is(err, sql.ErrNoRows) {
			continue
		}
		if err != nil {
			return QueueJob{}, false, err
		}

		res, err := q.store.DB().Exec(`
			UPDATE identify_queue
			SET status = 'processing', updated_at = ?
			WHERE id = ? AND status = 'queued'`,
			nowMs, job.ID,
		)
		if err != nil {
			return QueueJob{}, false, err
		}
		n, _ := res.RowsAffected()
		if n == 1 {
			q.lastHouseID = hhID
			return job, true, nil
		}
	}
	return QueueJob{}, false, nil
}

func classifyErrorCode(err error) string {
	switch {
	case err == nil:
		return ""
	case errors.Is(err, metadata.ErrTmdbUpstream):
		return "tmdb_upstream"
	case errors.Is(err, metadata.ErrUpstream):
		return "provider_upstream"
	case errors.Is(err, metadata.ErrNotConfigured):
		return "provider_not_configured"
	case errors.Is(err, metadata.ErrNotFound):
		return "not_found"
	case errors.Is(err, metadata.ErrInvalidInput):
		return "invalid_input"
	case errors.Is(err, context.DeadlineExceeded):
		return "timeout"
	default:
		return "identify_failed"
	}
}
