package storage

import (
	"path"
	"strings"
)

const RootPath = "/"

// NormalizePath collapses separators, resolves '.' and '..', and returns a
// mount-relative POSIX path starting with '/' with no trailing slash (except "/").
func NormalizePath(raw string) string {
	replaced := strings.ReplaceAll(strings.TrimSpace(raw), "\\", "/")
	var parts []string
	for _, seg := range strings.Split(replaced, "/") {
		if seg == "" || seg == "." {
			continue
		}
		if seg == ".." {
			if len(parts) > 0 {
				parts = parts[:len(parts)-1]
			}
			continue
		}
		parts = append(parts, seg)
	}
	if len(parts) == 0 {
		return RootPath
	}
	return "/" + strings.Join(parts, "/")
}

func PathSegments(p string) []string {
	norm := NormalizePath(p)
	if norm == RootPath {
		return nil
	}
	return strings.Split(norm[1:], "/")
}

func JoinPath(parent, name string) string {
	return NormalizePath(parent + "/" + name)
}

func ParentPath(p string) string {
	segs := PathSegments(p)
	if len(segs) <= 1 {
		return RootPath
	}
	return "/" + strings.Join(segs[:len(segs)-1], "/")
}

func BaseName(p string) string {
	segs := PathSegments(p)
	if len(segs) == 0 {
		return ""
	}
	return segs[len(segs)-1]
}

func ExtLower(p string) string {
	base := BaseName(p)
	idx := strings.LastIndexByte(base, '.')
	if idx <= 0 || idx == len(base)-1 {
		return ""
	}
	return strings.ToLower(base[idx+1:])
}

func PathFilterFromConfig(cfg map[string]any) (includes []string, excludes []string) {
	readList := func(key string) []string {
		raw, ok := cfg[key]
		if !ok || raw == nil {
			return nil
		}
		var out []string
		switch v := raw.(type) {
		case []string:
			for _, item := range v {
				if t := strings.TrimSpace(item); t != "" {
					out = append(out, NormalizePath(t))
				}
			}
		case []any:
			for _, item := range v {
				if s, ok := item.(string); ok {
					if t := strings.TrimSpace(s); t != "" {
						out = append(out, NormalizePath(t))
					}
				}
			}
		}
		return out
	}
	return readList("includePaths"), readList("excludePaths")
}

func IsExcludedPath(mountRelPath string, excludes []string) bool {
	if len(excludes) == 0 {
		return false
	}
	norm := NormalizePath(mountRelPath)
	for _, ex := range excludes {
		if ex == RootPath {
			return true
		}
		if norm == ex || strings.HasPrefix(norm, ex+"/") {
			return true
		}
	}
	return false
}

func CanTraverseDir(dirPath string, includes, excludes []string) bool {
	normDir := NormalizePath(dirPath)
	if IsExcludedPath(normDir, excludes) {
		return false
	}
	if len(includes) == 0 || normDir == RootPath {
		return true
	}
	for _, inc := range includes {
		if inc == RootPath || normDir == inc || strings.HasPrefix(normDir, inc+"/") || strings.HasPrefix(inc, normDir+"/") {
			return true
		}
	}
	return false
}

func IsFileAllowed(filePath string, includes, excludes []string) bool {
	normFile := NormalizePath(filePath)
	if IsExcludedPath(normFile, excludes) {
		return false
	}
	if len(includes) == 0 {
		return true
	}
	for _, inc := range includes {
		if inc == RootPath || normFile == inc || strings.HasPrefix(normFile, inc+"/") {
			return true
		}
	}
	return false
}

// SafeMimeExt extracts extension cleanly for Content-Type hints.
func SafeMimeExt(name string) string {
	return strings.ToLower(path.Ext(name))
}
