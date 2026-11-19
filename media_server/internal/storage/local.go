package storage

import (
	"context"
	"errors"
	"io"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
)

type LocalDriver struct {
	rootAbs string
}

func NewLocalDriver(rootPath string, allowedRoots []string) (*LocalDriver, error) {
	cleaned := strings.TrimSpace(rootPath)
	if cleaned == "" {
		return nil, NewError(ErrKindOther, "local mount requires rootPath")
	}
	abs, err := filepath.Abs(cleaned)
	if err != nil {
		return nil, NewError(ErrKindOther, "invalid local rootPath", err)
	}
	if realPath, err := filepath.EvalSymlinks(abs); err == nil {
		abs = realPath
	}
	if !isPathWithinAllowedRoots(abs, allowedRoots) {
		return nil, NewError(ErrKindUnauthorized, "local rootPath is outside allowed server directories")
	}
	return &LocalDriver{rootAbs: abs}, nil
}

func isPathWithinAllowedRoots(abs string, allowedRoots []string) bool {
	if len(allowedRoots) == 0 {
		return true
	}
	cleanTarget := filepath.Clean(abs)
	for _, raw := range allowedRoots {
		r, err := filepath.Abs(strings.TrimSpace(raw))
		if err != nil {
			continue
		}
		if realR, err := filepath.EvalSymlinks(r); err == nil {
			r = realR
		}
		r = filepath.Clean(r)
		if isSameOrSubpath(cleanTarget, r) {
			return true
		}
	}
	return false
}

func isSameOrSubpath(target, root string) bool {
	if runtime.GOOS == "windows" {
		target = strings.ToLower(target)
		root = strings.ToLower(root)
	}
	if target == root {
		return true
	}
	rel, err := filepath.Rel(root, target)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func (d *LocalDriver) Kind() string {
	return "local"
}

func (d *LocalDriver) RootAbs() string {
	return d.rootAbs
}

func (d *LocalDriver) resolveOSPath(mountPath string) (string, string, error) {
	norm := NormalizePath(mountPath)
	segs := PathSegments(norm)
	target := filepath.Join(append([]string{d.rootAbs}, segs...)...)
	target = filepath.Clean(target)
	if !isSameOrSubpath(target, d.rootAbs) {
		return "", "", NewError(ErrKindUnauthorized, "path escapes mount root")
	}
	return norm, target, nil
}

func (d *LocalDriver) Check(ctx context.Context) error {
	info, err := os.Stat(d.rootAbs)
	if err != nil {
		if os.IsNotExist(err) {
			return NewError(ErrKindNotFound, "local directory does not exist: "+d.rootAbs, err)
		}
		if os.IsPermission(err) {
			return NewError(ErrKindUnauthorized, "permission denied accessing: "+d.rootAbs, err)
		}
		return NewError(ErrKindOther, "cannot access local directory", err)
	}
	if !info.IsDir() {
		return NewError(ErrKindOther, "local rootPath is not a directory")
	}
	return nil
}

func (d *LocalDriver) List(ctx context.Context, path string, parent *Entry) ([]Entry, error) {
	norm, osPath, err := d.resolveOSPath(path)
	if err != nil {
		return nil, err
	}
	dirEntries, err := os.ReadDir(osPath)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, NewError(ErrKindNotFound, "directory not found: "+norm, err)
		}
		if os.IsPermission(err) {
			return nil, NewError(ErrKindUnauthorized, "permission denied: "+norm, err)
		}
		return nil, NewError(ErrKindOther, "list local directory failed", err)
	}

	out := make([]Entry, 0, len(dirEntries))
	for _, de := range dirEntries {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
		}
		name := de.Name()
		if name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
			continue
		}
		childOS := filepath.Join(osPath, name)
		info, err := os.Stat(childOS)
		if err != nil {
			continue
		}
		// Prevent symlinks pointing outside rootAbs from leaking host files.
		if realChild, err := filepath.EvalSymlinks(childOS); err == nil {
			if !isSameOrSubpath(realChild, d.rootAbs) {
				continue
			}
		}
		isDir := info.IsDir()
		modMs := info.ModTime().UnixMilli()
		entry := Entry{
			Path:       JoinPath(norm, name),
			Name:       name,
			IsDir:      isDir,
			ModifiedAt: &modMs,
		}
		if !isDir {
			sz := info.Size()
			entry.Size = &sz
		}
		out = append(out, entry)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].IsDir != out[j].IsDir {
			return out[i].IsDir
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out, nil
}

func (d *LocalDriver) Stat(ctx context.Context, path string) (Entry, error) {
	norm, osPath, err := d.resolveOSPath(path)
	if err != nil {
		return Entry{}, err
	}
	info, err := os.Stat(osPath)
	if err != nil {
		if os.IsNotExist(err) {
			return Entry{}, NewError(ErrKindNotFound, "not found: "+norm, err)
		}
		return Entry{}, NewError(ErrKindOther, "stat local path failed", err)
	}
	if realPath, err := filepath.EvalSymlinks(osPath); err == nil && !isSameOrSubpath(realPath, d.rootAbs) {
		return Entry{}, NewError(ErrKindUnauthorized, "symlink escapes mount root")
	}
	isDir := info.IsDir()
	modMs := info.ModTime().UnixMilli()
	entry := Entry{
		Path:       norm,
		Name:       BaseName(norm),
		IsDir:      isDir,
		ModifiedAt: &modMs,
	}
	if !isDir {
		sz := info.Size()
		entry.Size = &sz
	}
	return entry, nil
}

type sectionReadCloser struct {
	file   *os.File
	reader io.Reader
}

func (s *sectionReadCloser) Read(p []byte) (int, error) {
	return s.reader.Read(p)
}

func (s *sectionReadCloser) Close() error {
	return s.file.Close()
}

func (d *LocalDriver) OpenRange(ctx context.Context, entry Entry, start int64, end *int64, forceRefresh bool) (RangeResult, error) {
	if entry.IsDir {
		return RangeResult{}, NewError(ErrKindUnsupported, "cannot stream a directory")
	}
	_, osPath, err := d.resolveOSPath(entry.Path)
	if err != nil {
		return RangeResult{}, err
	}
	f, err := os.Open(osPath)
	if err != nil {
		if os.IsNotExist(err) {
			return RangeResult{}, NewError(ErrKindNotFound, "file not found: "+entry.Path, err)
		}
		if os.IsPermission(err) {
			return RangeResult{}, NewError(ErrKindUnauthorized, "permission denied: "+entry.Path, err)
		}
		return RangeResult{}, NewError(ErrKindOther, "open local file failed", err)
	}
	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return RangeResult{}, NewError(ErrKindOther, "stat local file failed", err)
	}
	total := info.Size()
	if total == 0 {
		return RangeResult{Body: f, TotalSize: 0, Start: 0, End: -1}, nil
	}
	if start < 0 {
		start = 0
	}
	if start >= total {
		_ = f.Close()
		return RangeResult{}, NewError(ErrKindOther, "range start beyond end of file")
	}
	effectiveEnd := total - 1
	if end != nil && *end < effectiveEnd {
		effectiveEnd = *end
	}
	if effectiveEnd < start {
		_ = f.Close()
		return RangeResult{}, NewError(ErrKindOther, "invalid byte range")
	}
	if _, err := f.Seek(start, io.SeekStart); err != nil {
		_ = f.Close()
		return RangeResult{}, NewError(ErrKindOther, "seek local file failed", err)
	}
	limit := effectiveEnd - start + 1
	return RangeResult{
		Body:      &sectionReadCloser{file: f, reader: io.LimitReader(f, limit)},
		TotalSize: total,
		Start:     start,
		End:       effectiveEnd,
	}, nil
}

func (d *LocalDriver) Close() error {
	return nil
}

type HostDirItem struct {
	Name string `json:"name"`
	Path string `json:"path"`
}

type HostBrowseResult struct {
	Current string        `json:"current"`
	Parent  string        `json:"parent,omitempty"`
	Dirs    []HostDirItem `json:"dirs"`
}

// BrowseHostDirectories enumerates host filesystem directories (and drive roots on Windows)
// to power the Web directory picker, respecting allowedRoots when configured.
func BrowseHostDirectories(rawPath string, allowedRoots []string) (HostBrowseResult, error) {
	trimmed := strings.TrimSpace(rawPath)
	if trimmed == "" {
		if len(allowedRoots) > 0 {
			dirs := make([]HostDirItem, 0, len(allowedRoots))
			for _, r := range allowedRoots {
				abs, err := filepath.Abs(strings.TrimSpace(r))
				if err != nil {
					continue
				}
				if info, err := os.Stat(abs); err == nil && info.IsDir() {
					dirs = append(dirs, HostDirItem{Name: abs, Path: abs})
				}
			}
			return HostBrowseResult{Current: "", Dirs: dirs}, nil
		}
		if runtime.GOOS == "windows" {
			drives := make([]HostDirItem, 0)
			for ch := 'A'; ch <= 'Z'; ch++ {
				root := string(ch) + `:\`
				if info, err := os.Stat(root); err == nil && info.IsDir() {
					drives = append(drives, HostDirItem{Name: string(ch) + ":", Path: root})
				}
			}
			return HostBrowseResult{Current: "", Dirs: drives}, nil
		}
		trimmed = "/"
	}

	abs, err := filepath.Abs(trimmed)
	if err != nil {
		return HostBrowseResult{}, NewError(ErrKindOther, "invalid path", err)
	}
	if !isPathWithinAllowedRoots(abs, allowedRoots) {
		return HostBrowseResult{}, NewError(ErrKindUnauthorized, "path is outside allowed roots")
	}
	entries, err := os.ReadDir(abs)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return HostBrowseResult{}, NewError(ErrKindNotFound, "directory not found", err)
		}
		if errors.Is(err, os.ErrPermission) {
			return HostBrowseResult{}, NewError(ErrKindUnauthorized, "permission denied", err)
		}
		return HostBrowseResult{}, NewError(ErrKindOther, "cannot read directory", err)
	}

	dirs := make([]HostDirItem, 0)
	for _, e := range entries {
		name := e.Name()
		if strings.HasPrefix(name, "$") || strings.EqualFold(name, "System Volume Information") {
			continue
		}
		full := filepath.Join(abs, name)
		info, err := os.Stat(full)
		if err != nil || !info.IsDir() {
			continue
		}
		dirs = append(dirs, HostDirItem{Name: name, Path: full})
	}
	sort.Slice(dirs, func(i, j int) bool {
		return strings.ToLower(dirs[i].Name) < strings.ToLower(dirs[j].Name)
	})

	parent := filepath.Dir(abs)
	if parent == abs {
		if runtime.GOOS == "windows" || len(allowedRoots) > 0 {
			parent = ""
		}
	} else if !isPathWithinAllowedRoots(parent, allowedRoots) {
		parent = ""
	}

	return HostBrowseResult{
		Current: abs,
		Parent:  parent,
		Dirs:    dirs,
	}, nil
}
