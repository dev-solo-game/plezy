package library

import (
	"strings"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/pathutil"
)

var (
	videoExts = map[string]bool{
		"mkv": true, "mp4": true, "m4v": true, "mov": true, "avi": true,
		"wmv": true, "flv": true, "f4v": true, "webm": true, "ts": true,
		"m2ts": true, "mts": true, "mpg": true, "mpeg": true, "rmvb": true,
		"rm": true, "3gp": true, "ogv": true,
	}
	subtitleExts = map[string]bool{
		"srt": true, "ass": true, "ssa": true, "vtt": true, "sub": true, "sup": true, "smi": true,
	}
	imageExts = map[string]bool{
		"jpg": true, "jpeg": true, "png": true, "webp": true,
	}
	skippedFolders = map[string]bool{
		"@eadir": true, "#recycle": true, "$recycle.bin": true,
		"system volume information": true, "lost+found": true, ".trash": true,
		"bdmv": true, "certificate": true, "video_ts": true,
		"extras": true, "extra": true, "featurettes": true, "behind the scenes": true,
		"deleted scenes": true, "interviews": true, "trailers": true, "samples": true,
		"sample": true, "screens": true, "screenshots": true, "proof": true,
		"花絮": true, "特典": true, "预告": true, "預告": true, "样片": true, "樣片": true,
	}
)

// IsSampleName reports whether a filename stem looks like a sample, trailer, teaser, or preview clip.
func IsSampleName(baseName string) bool {
	low := strings.ToLower(baseName)
	for _, kw := range []string{"sample", "trailer", "teaser", "preview"} {
		idx := strings.Index(low, kw)
		for idx >= 0 {
			leftOk := idx == 0 || isSampleSep(low[idx-1])
			rightIdx := idx + len(kw)
			rightOk := rightIdx == len(low) || isSampleSep(low[rightIdx])
			if leftOk && rightOk {
				return true
			}
			next := strings.Index(low[idx+1:], kw)
			if next < 0 {
				break
			}
			idx = idx + 1 + next
		}
	}
	return false
}

func isSampleSep(b byte) bool {
	return b == ' ' || b == '.' || b == '_' || b == '-' || b == '[' || b == ']' || b == '(' || b == ')'
}

// FileStem returns the filename without its last extension.
func FileStem(name string) string {
	idx := strings.LastIndexByte(name, '.')
	if idx <= 0 {
		return name
	}
	return name[:idx]
}

// IsVideoFile reports whether name has a supported video extension and is not a sample clip.
func IsVideoFile(name string) bool {
	ext := pathutil.ExtLower(name)
	if !videoExts[ext] {
		return false
	}
	return !IsSampleName(FileStem(name))
}

func IsSubtitleFile(name string) bool {
	return subtitleExts[pathutil.ExtLower(name)]
}

func IsArtworkFile(name string) bool {
	return imageExts[pathutil.ExtLower(name)]
}

func IsNfoFile(name string) bool {
	return pathutil.ExtLower(name) == "nfo"
}

func IsSkippedFolder(name string) bool {
	if strings.HasPrefix(name, ".") {
		return true
	}
	return skippedFolders[strings.ToLower(name)]
}

// ClassifyFileRole maps a filename to a media file role constant, or "" if ignored.
func ClassifyFileRole(name string) string {
	switch {
	case IsVideoFile(name):
		return db.FileRoleVideo
	case IsSubtitleFile(name):
		return db.FileRoleSubtitle
	case IsArtworkFile(name):
		return db.FileRoleArtwork
	case IsNfoFile(name):
		return db.FileRoleNfo
	default:
		return ""
	}
}

type DirFile struct {
	Path string
	Name string
}

type MatchedSubtitle struct {
	Subtitle DirFile
	Owner    DirFile
	Language string
}

// MatchSubtitles associates subtitle files in the same directory with their owning video files.
func MatchSubtitles(files []DirFile) []MatchedSubtitle {
	var videos, subs []DirFile
	for _, f := range files {
		if IsVideoFile(f.Name) {
			videos = append(videos, f)
		} else if IsSubtitleFile(f.Name) {
			subs = append(subs, f)
		}
	}
	if len(videos) == 0 || len(subs) == 0 {
		return nil
	}

	var out []MatchedSubtitle
	for _, sub := range subs {
		subStem := FileStem(sub.Name)
		lowSub := strings.ToLower(subStem)

		var bestOwner *DirFile
		var bestScore int
		for i := range videos {
			v := &videos[i]
			vStem := strings.ToLower(FileStem(v.Name))
			if lowSub == vStem {
				bestOwner = v
				bestScore = len(vStem) + 100
				break
			}
			if strings.HasPrefix(lowSub, vStem+".") || strings.HasPrefix(lowSub, vStem+"-") || strings.HasPrefix(lowSub, vStem+"_") {
				if len(vStem) > bestScore {
					bestOwner = v
					bestScore = len(vStem)
				}
			}
		}
		if bestOwner == nil && len(videos) == 1 {
			bestOwner = &videos[0]
		}
		if bestOwner == nil {
			continue
		}
		lang := GuessSubtitleLanguage(subStem, FileStem(bestOwner.Name))
		out = append(out, MatchedSubtitle{
			Subtitle: sub,
			Owner:    *bestOwner,
			Language: lang,
		})
	}
	return out
}

func GuessSubtitleLanguage(subStem, videoStem string) string {
	rest := subStem
	if strings.HasPrefix(strings.ToLower(subStem), strings.ToLower(videoStem)) {
		rest = subStem[len(videoStem):]
	}
	rest = strings.TrimLeft(rest, "._- ")
	if rest == "" {
		return ""
	}
	parts := strings.FieldsFunc(rest, func(r rune) bool { return r == '.' || r == '_' || r == '-' || r == ' ' })
	if len(parts) == 0 {
		return ""
	}
	return strings.ToLower(parts[len(parts)-1])
}
