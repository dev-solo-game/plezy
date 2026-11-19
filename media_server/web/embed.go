package web

import (
	"bytes"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
)

func isRegularFile(p string) bool {
	info, err := os.Stat(p)
	return err == nil && !info.IsDir()
}

func isBuiltIndexHTML(p string) bool {
	raw, err := os.ReadFile(p)
	if err != nil {
		return false
	}
	// Reject Vite dev template web/index.html which points to /src/main.tsx.
	return !bytes.Contains(raw, []byte("/src/main.tsx"))
}

// ResolveDiskFS locates built frontend static assets on disk without embedding them into the binary.
// Search order:
// 1. Explicit customDir (<customDir>/dist if present, otherwise <customDir>).
// 2. <cwd>/web/dist, <cwd>/web (when flat built assets), <exeDir>/web/dist, <exeDir>/web.
func ResolveDiskFS(customDir string) (fs.FS, string) {
	if custom := strings.TrimSpace(customDir); custom != "" {
		distSub := filepath.Join(custom, "dist")
		if isRegularFile(filepath.Join(distSub, "index.html")) {
			return os.DirFS(distSub), distSub
		}
		if info, err := os.Stat(custom); err == nil && info.IsDir() {
			return os.DirFS(custom), custom
		}
		return nil, ""
	}

	var bases []string
	addBase := func(dir string) {
		dir = strings.TrimSpace(dir)
		if dir == "" {
			return
		}
		abs, err := filepath.Abs(dir)
		if err == nil {
			dir = abs
		}
		for _, existing := range bases {
			if strings.EqualFold(existing, dir) {
				return
			}
		}
		bases = append(bases, dir)
	}

	if wd, err := os.Getwd(); err == nil {
		addBase(wd)
	}
	if exe, err := os.Executable(); err == nil {
		addBase(filepath.Dir(exe))
	}

	for _, base := range bases {
		distCandidate := filepath.Join(base, "web", "dist")
		if isRegularFile(filepath.Join(distCandidate, "index.html")) {
			return os.DirFS(distCandidate), distCandidate
		}
		flatCandidate := filepath.Join(base, "web")
		if isBuiltIndexHTML(filepath.Join(flatCandidate, "index.html")) {
			return os.DirFS(flatCandidate), flatCandidate
		}
	}
	return nil, ""
}
