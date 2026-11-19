package stream

import (
	"errors"
	"fmt"
	"io"
	"net/http"
	"strconv"
	"strings"

	"plezy/media_server/internal/storage"
)

func ContentTypeForExt(ext string) string {
	switch strings.ToLower(strings.TrimPrefix(ext, ".")) {
	case "mp4", "m4v":
		return "video/mp4"
	case "mkv":
		return "video/x-matroska"
	case "webm":
		return "video/webm"
	case "mov":
		return "video/quicktime"
	case "avi":
		return "video/x-msvideo"
	case "ts", "mts", "m2ts":
		return "video/mp2t"
	case "flv":
		return "video/x-flv"
	case "wmv":
		return "video/x-ms-wmv"
	case "m3u8":
		return "application/vnd.apple.mpegurl"
	case "vtt":
		return "text/vtt; charset=utf-8"
	case "srt":
		return "application/x-subrip; charset=utf-8"
	case "ass", "ssa":
		return "text/x-ssa; charset=utf-8"
	case "jpg", "jpeg":
		return "image/jpeg"
	case "png":
		return "image/png"
	case "webp":
		return "image/webp"
	default:
		return "application/octet-stream"
	}
}

type byteRange struct {
	start int64
	end   int64
}

var errUnsatisfiableRange = errors.New("unsatisfiable byte range")

func parseSingleRange(header string, totalSize int64) (*byteRange, error) {
	h := strings.TrimSpace(header)
	if h == "" {
		return nil, nil
	}
	if !strings.HasPrefix(strings.ToLower(h), "bytes=") {
		return nil, errUnsatisfiableRange
	}
	spec := strings.TrimSpace(h[6:])
	if spec == "" || strings.Contains(spec, ",") {
		return nil, errUnsatisfiableRange
	}
	dash := strings.IndexByte(spec, '-')
	if dash < 0 || totalSize <= 0 {
		return nil, errUnsatisfiableRange
	}
	left := strings.TrimSpace(spec[:dash])
	right := strings.TrimSpace(spec[dash+1:])
	if left == "" && right == "" {
		return nil, errUnsatisfiableRange
	}
	if left == "" {
		suffix, err := strconv.ParseInt(right, 10, 64)
		if err != nil || suffix <= 0 {
			return nil, errUnsatisfiableRange
		}
		start := totalSize - suffix
		if start < 0 {
			start = 0
		}
		return &byteRange{start: start, end: totalSize - 1}, nil
	}
	start, err := strconv.ParseInt(left, 10, 64)
	if err != nil || start < 0 || start >= totalSize {
		return nil, errUnsatisfiableRange
	}
	end := totalSize - 1
	if right != "" {
		parsedEnd, err := strconv.ParseInt(right, 10, 64)
		if err != nil || parsedEnd < start {
			return nil, errUnsatisfiableRange
		}
		if parsedEnd < end {
			end = parsedEnd
		}
	}
	return &byteRange{start: start, end: end}, nil
}

// ServeDriverRange serves GET or HEAD HTTP byte-range responses from any storage.Driver.
func ServeDriverRange(w http.ResponseWriter, r *http.Request, drv storage.Driver, entry storage.Entry) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		w.Header().Set("Allow", "GET, HEAD")
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	ctx := r.Context()
	totalSize := int64(-1)
	if entry.Size != nil && *entry.Size >= 0 {
		totalSize = *entry.Size
	}
	if totalSize < 0 {
		st, err := drv.Stat(ctx, entry.Path)
		if err != nil {
			writeStorageHTTPError(w, err)
			return
		}
		entry = st
		if st.Size != nil {
			totalSize = *st.Size
		}
	}

	contentType := ContentTypeForExt(storage.ExtLower(entry.Name))
	rangeHeader := r.Header.Get("Range")

	if r.Method == http.MethodHead && totalSize >= 0 {
		rng, err := parseSingleRange(rangeHeader, totalSize)
		if err != nil {
			w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", totalSize))
			http.Error(w, "range not satisfiable", http.StatusRequestedRangeNotSatisfiable)
			return
		}
		w.Header().Set("Accept-Ranges", "bytes")
		w.Header().Set("Content-Type", contentType)
		if rng != nil {
			length := rng.end - rng.start + 1
			w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", rng.start, rng.end, totalSize))
			w.Header().Set("Content-Length", strconv.FormatInt(length, 10))
			w.WriteHeader(http.StatusPartialContent)
		} else {
			w.Header().Set("Content-Length", strconv.FormatInt(totalSize, 10))
			w.WriteHeader(http.StatusOK)
		}
		return
	}

	var rng *byteRange
	if totalSize >= 0 && rangeHeader != "" {
		parsed, err := parseSingleRange(rangeHeader, totalSize)
		if err != nil {
			w.Header().Set("Content-Range", fmt.Sprintf("bytes */%d", totalSize))
			http.Error(w, "range not satisfiable", http.StatusRequestedRangeNotSatisfiable)
			return
		}
		rng = parsed
	}

	start := int64(0)
	var endPtr *int64
	if rng != nil {
		start = rng.start
		e := rng.end
		endPtr = &e
	}

	rr, err := drv.OpenRange(ctx, entry, start, endPtr, false)
	if err != nil {
		writeStorageHTTPError(w, err)
		return
	}
	defer rr.Body.Close()

	effTotal := rr.TotalSize
	if effTotal < 0 {
		effTotal = totalSize
	}

	// Read a small initial probe slice before writing headers so upstream
	// failures (e.g. expired link / unreadable file) return a proper HTTP error.
	var firstBuf [1]byte
	var firstN int
	var readErr error
	if r.Method == http.MethodGet && effTotal != 0 {
		firstN, readErr = rr.Body.Read(firstBuf[:])
		if readErr != nil && !errors.Is(readErr, io.EOF) {
			writeStorageHTTPError(w, readErr)
			return
		}
	}

	w.Header().Set("Accept-Ranges", "bytes")
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", "no-store")

	if rng != nil && effTotal > 0 {
		effEnd := rng.end
		if rr.End >= 0 && rr.End < effEnd {
			effEnd = rr.End
		}
		length := effEnd - rng.start + 1
		if length < 0 {
			length = 0
		}
		w.Header().Set("Content-Range", fmt.Sprintf("bytes %d-%d/%d", rng.start, effEnd, effTotal))
		w.Header().Set("Content-Length", strconv.FormatInt(length, 10))
		w.WriteHeader(http.StatusPartialContent)
	} else if effTotal >= 0 {
		w.Header().Set("Content-Length", strconv.FormatInt(effTotal, 10))
		w.WriteHeader(http.StatusOK)
	} else {
		w.WriteHeader(http.StatusOK)
	}

	if r.Method == http.MethodHead {
		return
	}
	if firstN > 0 {
		if _, err := w.Write(firstBuf[:firstN]); err != nil {
			return
		}
	}
	if !errors.Is(readErr, io.EOF) {
		_, _ = io.Copy(w, rr.Body)
	}
}

func writeStorageHTTPError(w http.ResponseWriter, err error) {
	switch {
	case storage.IsKind(err, storage.ErrKindNotFound):
		http.Error(w, err.Error(), http.StatusNotFound)
	case storage.IsKind(err, storage.ErrKindUnauthorized):
		http.Error(w, err.Error(), http.StatusUnauthorized)
	case storage.IsKind(err, storage.ErrKindRateLimited):
		http.Error(w, err.Error(), http.StatusTooManyRequests)
	case storage.IsKind(err, storage.ErrKindNetwork):
		http.Error(w, err.Error(), http.StatusBadGateway)
	default:
		http.Error(w, err.Error(), http.StatusInternalServerError)
	}
}
