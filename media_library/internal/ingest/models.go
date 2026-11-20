package ingest

import (
	"time"

	"plezy/media_library/internal/db"
)

const (
	ScanTypeFull        = "full"
	ScanTypeIncremental = "incremental"
	ScanTypeFolder      = "folder"

	SessionRunning   = "running"
	SessionCompleted = "completed"
	SessionPartial   = "partial"
	SessionStale     = "stale"

	SidecarKindNfo     = "nfo"
	SidecarKindArtwork = "artwork"

	MaxNfoSidecarBytes     = 64 * 1024
	MaxArtworkSidecarBytes = 300 * 1024

	StaleSessionTimeout      = 30 * time.Minute
	IdentifyDebounceDuration = 10 * time.Second

	DefaultBulkDeleteMinCount = 100
	DefaultBulkDeleteRatio    = 0.50

	MaxItemsPerBatch     = 1000
	BatchRateLimitPerMin = 60
)

type CreateSessionRequest struct {
	Type     string `json:"type"`
	FolderID string `json:"folder_id,omitempty"`
}

type ScanFolderScope struct {
	ID           string   `json:"id"`
	Path         string   `json:"path"`
	ExcludePaths []string `json:"exclude_paths"`
	LibraryHint  string   `json:"library_hint"`
}

type ScanSessionView struct {
	ID                   string            `json:"id"`
	HouseholdID          string            `json:"household_id"`
	SourceID             string            `json:"source_id"`
	FolderID             *string           `json:"folder_id,omitempty"`
	Type                 string            `json:"type"`
	DeviceID             string            `json:"device_id"`
	MemberID             string            `json:"member_id"`
	Status               string            `json:"status"`
	StartedAt            int64             `json:"started_at"`
	LastActivityAt       int64             `json:"last_activity_at"`
	FinishedAt           *int64            `json:"finished_at,omitempty"`
	FilesReported        int               `json:"files_reported"`
	FilesAdded           int               `json:"files_added"`
	FilesChanged         int               `json:"files_changed"`
	FilesMissing         int               `json:"files_missing"`
	ProgressPct          int               `json:"progress_pct"`
	Folders              []ScanFolderScope `json:"folders,omitempty"`
	IncrementalWatermark int64             `json:"incremental_watermark"`
}

type MediaSpecInput struct {
	DurationMs  *int64            `json:"duration_ms,omitempty"`
	BitrateKbps *int              `json:"bitrate_kbps,omitempty"`
	Container   *string           `json:"container,omitempty"`
	VideoCodec  *string           `json:"video_codec,omitempty"`
	Width       *int              `json:"width,omitempty"`
	Height      *int              `json:"height,omitempty"`
	HdrFormat   *string           `json:"hdr_format,omitempty"`
	Streams     []db.ProbedStream `json:"streams,omitempty"`
}

type BatchFileItem struct {
	Path        string          `json:"path"`
	RemoteID    *string         `json:"remote_id,omitempty"`
	Size        *int64          `json:"size,omitempty"`
	MtimeS      *int64          `json:"mtime_s,omitempty"`
	CtimeS      *int64          `json:"ctime_s,omitempty"`
	SidecarHash string          `json:"sidecar_hash,omitempty"`
	MediaSpec   *MediaSpecInput `json:"media_spec,omitempty"`
	ClientHints map[string]any  `json:"client_hints,omitempty"`
}

type BatchRemovedItem struct {
	Path     string `json:"path,omitempty"`
	RemoteID string `json:"remote_id,omitempty"`
}

type SubmitBatchRequest struct {
	BatchNo int                `json:"batch_no"`
	Upserts []BatchFileItem    `json:"upserts,omitempty"`
	Removed []BatchRemovedItem `json:"removed,omitempty"`
}

type BatchReceipt struct {
	BatchNo         int              `json:"batch_no"`
	Accepted        int              `json:"accepted"`
	Added           int              `json:"added"`
	Changed         int              `json:"changed"`
	Unchanged       int              `json:"unchanged"`
	Ignored         int              `json:"ignored"`
	Removed         int              `json:"removed"`
	FileIDs         map[string]int64 `json:"file_ids"`
	MissingSidecars []string         `json:"missing_sidecars"`
}

type ProgressRequest struct {
	ProgressPct   int  `json:"progress_pct"`
	FilesReported *int `json:"files_reported,omitempty"`
}

type CompleteSessionRequest struct {
	Complete     bool  `json:"complete"`
	NewWatermark int64 `json:"new_watermark,omitempty"`
}

type CompleteSessionResult struct {
	Session           ScanSessionView `json:"session"`
	MissingCount      int             `json:"missing_count"`
	PendingDeletionID string          `json:"pending_deletion_id,omitempty"`
	NewWatermark      int64           `json:"new_watermark"`
}

type PendingDeletionView struct {
	ID           string `json:"id"`
	HouseholdID  string `json:"household_id"`
	SourceID     string `json:"source_id"`
	SessionID    string `json:"session_id"`
	ScopePath    string `json:"scope_path"`
	FileCount    int    `json:"file_count"`
	TotalInScope int    `json:"total_in_scope"`
	Status       string `json:"status"`
	CreatedAt    int64  `json:"created_at"`
	ResolvedAt   *int64 `json:"resolved_at,omitempty"`
}
