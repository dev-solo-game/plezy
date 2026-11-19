package storage

import (
	"context"
	"errors"
	"io"
	"net"
	"os"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/hirochachacha/go-smb2"
)

type SmbDriver struct {
	host         string
	fallbackHost string
	shareName    string
	rootSegs     []string
	username     string
	password     string
	domain       string

	mu      sync.Mutex
	conn    net.Conn
	session *smb2.Session
	share   *smb2.Share
	closed  bool
}

func NewSmbDriver(cfg MountConfig) (*SmbDriver, error) {
	host := CfgString(cfg.Config, "host")
	shareName := CfgString(cfg.Config, "share")
	if host == "" || shareName == "" {
		return nil, NewError(ErrKindOther, "SMB mount requires host and share")
	}
	return &SmbDriver{
		host:         host,
		fallbackHost: CfgString(cfg.Config, "fallbackUrl"),
		shareName:    shareName,
		rootSegs:     PathSegments(CfgString(cfg.Config, "rootPath")),
		username:     CfgString(cfg.Config, "username"),
		password:     cfg.Secrets["password"],
		domain:       CfgString(cfg.Config, "domain"),
	}, nil
}

func (d *SmbDriver) Kind() string {
	return "smb"
}

func (d *SmbDriver) sharePath(mountPath string) string {
	segs := append(append([]string{}, d.rootSegs...), PathSegments(mountPath)...)
	return strings.Join(segs, "/")
}

func formatSmbAddr(host string) string {
	if strings.Contains(host, ":") {
		return host
	}
	return net.JoinHostPort(host, "445")
}

func (d *SmbDriver) connectOnce(ctx context.Context, host string) (net.Conn, *smb2.Session, *smb2.Share, error) {
	dialer := &net.Dialer{Timeout: 10 * time.Second}
	conn, err := dialer.DialContext(ctx, "tcp", formatSmbAddr(host))
	if err != nil {
		return nil, nil, nil, NewError(ErrKindNetwork, "cannot connect to SMB host "+host, err)
	}
	smbDialer := &smb2.Dialer{
		Initiator: &smb2.NTLMInitiator{
			User:     d.username,
			Password: d.password,
			Domain:   d.domain,
		},
	}
	sess, err := smbDialer.DialContext(ctx, conn)
	if err != nil {
		_ = conn.Close()
		return nil, nil, nil, translateSmbErr(err, "SMB authentication failed")
	}
	sh, err := sess.Mount(d.shareName)
	if err != nil {
		_ = sess.Logoff()
		_ = conn.Close()
		return nil, nil, nil, translateSmbErr(err, "cannot mount SMB share "+d.shareName)
	}
	return conn, sess, sh, nil
}

func (d *SmbDriver) ensureShare(ctx context.Context) (*smb2.Share, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	if d.closed {
		return nil, NewError(ErrKindOther, "SMB driver is closed")
	}
	if d.share != nil {
		return d.share, nil
	}

	conn, sess, sh, err := d.connectOnce(ctx, d.host)
	if err != nil && d.fallbackHost != "" && IsKind(err, ErrKindNetwork) {
		conn, sess, sh, err = d.connectOnce(ctx, d.fallbackHost)
	}
	if err != nil {
		return nil, err
	}
	d.conn = conn
	d.session = sess
	d.share = sh
	return sh, nil
}

func (d *SmbDriver) resetSession() {
	d.mu.Lock()
	sh := d.share
	sess := d.session
	conn := d.conn
	d.share = nil
	d.session = nil
	d.conn = nil
	d.mu.Unlock()

	if sh != nil {
		_ = sh.Umount()
	}
	if sess != nil {
		_ = sess.Logoff()
	}
	if conn != nil {
		_ = conn.Close()
	}
}

func translateSmbErr(err error, msg string) error {
	if err == nil {
		return nil
	}
	var se *StorageError
	if errors.As(err, &se) {
		return se
	}
	if errors.Is(err, os.ErrNotExist) {
		return NewError(ErrKindNotFound, msg, err)
	}
	if errors.Is(err, os.ErrPermission) {
		return NewError(ErrKindUnauthorized, msg, err)
	}
	lower := strings.ToLower(err.Error())
	switch {
	case strings.Contains(lower, "logon failure") || strings.Contains(lower, "access is denied") || strings.Contains(lower, "status_access_denied"):
		return NewError(ErrKindUnauthorized, msg, err)
	case strings.Contains(lower, "not found") || strings.Contains(lower, "no such file") || strings.Contains(lower, "object_name_not_found") || strings.Contains(lower, "object_path_not_found"):
		return NewError(ErrKindNotFound, msg, err)
	case strings.Contains(lower, "connection") || strings.Contains(lower, "timeout") || strings.Contains(lower, "eof") || strings.Contains(lower, "broken pipe"):
		return NewError(ErrKindNetwork, msg, err)
	default:
		return NewError(ErrKindOther, msg, err)
	}
}

func (d *SmbDriver) Check(ctx context.Context) error {
	sh, err := d.ensureShare(ctx)
	if err != nil {
		return err
	}
	_, err = sh.WithContext(ctx).ReadDir(d.sharePath(RootPath))
	if err != nil {
		mapped := translateSmbErr(err, "SMB directory check failed")
		if IsKind(mapped, ErrKindNetwork) {
			d.resetSession()
		}
		return mapped
	}
	return nil
}

func (d *SmbDriver) List(ctx context.Context, mountPath string, parent *Entry) ([]Entry, error) {
	norm := NormalizePath(mountPath)
	sh, err := d.ensureShare(ctx)
	if err != nil {
		return nil, err
	}
	infos, err := sh.WithContext(ctx).ReadDir(d.sharePath(norm))
	if err != nil {
		mapped := translateSmbErr(err, "SMB list failed: "+norm)
		if IsKind(mapped, ErrKindNetwork) {
			d.resetSession()
		}
		return nil, mapped
	}

	out := make([]Entry, 0, len(infos))
	for _, info := range infos {
		name := info.Name()
		if name == "." || name == ".." || strings.ContainsAny(name, `/\`) {
			continue
		}
		isDir := info.IsDir()
		modMs := info.ModTime().UnixMilli()
		e := Entry{
			Path:       JoinPath(norm, name),
			Name:       name,
			IsDir:      isDir,
			ModifiedAt: &modMs,
		}
		if !isDir {
			sz := info.Size()
			e.Size = &sz
		}
		out = append(out, e)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].IsDir != out[j].IsDir {
			return out[i].IsDir
		}
		return strings.ToLower(out[i].Name) < strings.ToLower(out[j].Name)
	})
	return out, nil
}

func (d *SmbDriver) Stat(ctx context.Context, mountPath string) (Entry, error) {
	norm := NormalizePath(mountPath)
	sh, err := d.ensureShare(ctx)
	if err != nil {
		return Entry{}, err
	}
	info, err := sh.WithContext(ctx).Stat(d.sharePath(norm))
	if err != nil {
		mapped := translateSmbErr(err, "SMB stat failed: "+norm)
		if IsKind(mapped, ErrKindNetwork) {
			d.resetSession()
		}
		return Entry{}, mapped
	}
	isDir := info.IsDir()
	modMs := info.ModTime().UnixMilli()
	e := Entry{
		Path:       norm,
		Name:       BaseName(norm),
		IsDir:      isDir,
		ModifiedAt: &modMs,
	}
	if !isDir {
		sz := info.Size()
		e.Size = &sz
	}
	return e, nil
}

type smbRangeReader struct {
	file   *smb2.File
	reader io.Reader
}

func (r *smbRangeReader) Read(p []byte) (int, error) {
	return r.reader.Read(p)
}

func (r *smbRangeReader) Close() error {
	return r.file.Close()
}

func (d *SmbDriver) OpenRange(ctx context.Context, entry Entry, start int64, end *int64, forceRefresh bool) (RangeResult, error) {
	if entry.IsDir {
		return RangeResult{}, NewError(ErrKindUnsupported, "cannot stream a directory")
	}
	sh, err := d.ensureShare(ctx)
	if err != nil {
		return RangeResult{}, err
	}
	f, err := sh.WithContext(ctx).Open(d.sharePath(entry.Path))
	if err != nil {
		mapped := translateSmbErr(err, "SMB open failed: "+entry.Path)
		if IsKind(mapped, ErrKindNetwork) {
			d.resetSession()
		}
		return RangeResult{}, mapped
	}
	info, err := f.Stat()
	if err != nil {
		_ = f.Close()
		return RangeResult{}, translateSmbErr(err, "SMB stat failed")
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
		return RangeResult{}, translateSmbErr(err, "SMB seek failed")
	}
	limit := effectiveEnd - start + 1
	return RangeResult{
		Body:      &smbRangeReader{file: f, reader: io.LimitReader(f, limit)},
		TotalSize: total,
		Start:     start,
		End:       effectiveEnd,
	}, nil
}

func (d *SmbDriver) Close() error {
	d.mu.Lock()
	d.closed = true
	d.mu.Unlock()
	d.resetSession()
	return nil
}
