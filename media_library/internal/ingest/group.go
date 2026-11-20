package ingest

import "plezy/media_library/internal/library"

// ParseAndGroup parses a normalized file path into naming tokens, version label,
// and an identify_queue deduplication group_key.
func ParseAndGroup(sourceID, normPath string) (parsed library.ParsedName, versionLabel string, groupKey string) {
	return library.ParseAndGroup(sourceID, normPath)
}
