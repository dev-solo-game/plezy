package library

import (
	"fmt"
	"strings"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/pathutil"
)

// ParseAndGroup parses a normalized file path into naming tokens, version label,
// and an identify_queue deduplication group_key.
func ParseAndGroup(sourceID, normPath string) (parsed ParsedName, versionLabel string, groupKey string) {
	base := pathutil.BaseName(normPath)
	parsed = ParseFileName(base)

	dir1 := pathutil.ParentPath(normPath)
	dir2 := pathutil.ParentPath(dir1)

	var parsedFolders []ParsedFolder
	if dir1 != pathutil.RootPath {
		parsedFolders = append(parsedFolders, ParseFolderName(pathutil.BaseName(dir1)))
	}
	if dir2 != pathutil.RootPath && dir2 != dir1 {
		parsedFolders = append(parsedFolders, ParseFolderName(pathutil.BaseName(dir2)))
	}

	cls := ClassifyVideo(parsed, parsedFolders, 0)
	versionLabel = cls.VersionLabel

	inSeasonFolder := len(parsedFolders) > 0 && parsedFolders[0].IsSeasonFolder
	if cls.Kind == db.KindEpisode || inSeasonFolder {
		showDir := dir1
		if inSeasonFolder && dir2 != pathutil.RootPath {
			showDir = dir2
		}
		groupKey = fmt.Sprintf("%s:dir:%s", sourceID, showDir)
		return parsed, versionLabel, groupKey
	}

	groupKey = fmt.Sprintf("%s:file:%s", sourceID, normPath)
	return parsed, versionLabel, groupKey
}

// ParseGroupKey splits a deduplication group_key ("<source_id>:dir:<dir>" or
// "<source_id>:file:<path>") back into its source ID, grouping mode, and target path.
func ParseGroupKey(groupKey string) (sourceID, mode, targetPath string, ok bool) {
	if idx := strings.Index(groupKey, ":dir:"); idx > 0 {
		src := groupKey[:idx]
		p := groupKey[idx+len(":dir:"):]
		if src != "" && p != "" {
			return src, "dir", p, true
		}
	}
	if idx := strings.Index(groupKey, ":file:"); idx > 0 {
		src := groupKey[:idx]
		p := groupKey[idx+len(":file:"):]
		if src != "" && p != "" {
			return src, "file", p, true
		}
	}
	return "", "", "", false
}
