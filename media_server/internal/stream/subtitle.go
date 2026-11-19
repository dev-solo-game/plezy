package stream

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strconv"
	"strings"
	"unicode/utf8"

	"golang.org/x/text/encoding/simplifiedchinese"
	"golang.org/x/text/encoding/unicode"
	"golang.org/x/text/transform"

	"plezy/media_server/internal/storage"
)

var (
	reSrtTiming  = regexp.MustCompile(`(\d{1,2}:\d{2}:\d{2}),(\d{3})\s*-->\s*(\d{1,2}:\d{2}:\d{2}),(\d{3})`)
	reAssTag     = regexp.MustCompile(`\{[^}]*\}`)
	reMultiBlank = regexp.MustCompile(`\n{3,}`)
)

func DecodeSubtitleToUTF8(raw []byte) string {
	// UTF-8 BOM
	if bytes.HasPrefix(raw, []byte{0xEF, 0xBB, 0xBF}) {
		return strings.ReplaceAll(string(raw[3:]), "\r\n", "\n")
	}
	// UTF-16 LE BOM
	if bytes.HasPrefix(raw, []byte{0xFF, 0xFE}) {
		dec := unicode.UTF16(unicode.LittleEndian, unicode.UseBOM).NewDecoder()
		if out, _, err := transform.Bytes(dec, raw); err == nil {
			return strings.ReplaceAll(string(out), "\r\n", "\n")
		}
	}
	// UTF-16 BE BOM
	if bytes.HasPrefix(raw, []byte{0xFE, 0xFF}) {
		dec := unicode.UTF16(unicode.BigEndian, unicode.UseBOM).NewDecoder()
		if out, _, err := transform.Bytes(dec, raw); err == nil {
			return strings.ReplaceAll(string(out), "\r\n", "\n")
		}
	}
	if utf8.Valid(raw) {
		return strings.ReplaceAll(string(raw), "\r\n", "\n")
	}
	dec := simplifiedchinese.GB18030.NewDecoder()
	if out, _, err := transform.Bytes(dec, raw); err == nil {
		return strings.ReplaceAll(string(out), "\r\n", "\n")
	}
	return strings.ReplaceAll(string(raw), "\r\n", "\n")
}

func ConvertSubtitleToVTT(text string, ext string) string {
	norm := strings.ReplaceAll(strings.ReplaceAll(text, "\r\n", "\n"), "\r", "\n")
	switch strings.ToLower(strings.TrimPrefix(ext, ".")) {
	case "vtt":
		if strings.HasPrefix(strings.TrimSpace(norm), "WEBVTT") {
			return norm
		}
		return "WEBVTT\n\n" + norm
	case "srt":
		return srtToVTT(norm)
	case "ass", "ssa":
		return assToVTT(norm)
	default:
		return "WEBVTT\n\n" + norm
	}
}

func srtToVTT(srt string) string {
	lines := strings.Split(srt, "\n")
	var out []string
	out = append(out, "WEBVTT", "")
	for i := 0; i < len(lines); i++ {
		trimmed := strings.TrimSpace(lines[i])
		// Skip pure numeric cue index before a timestamp line
		if _, err := strconv.Atoi(trimmed); err == nil && i+1 < len(lines) && strings.Contains(lines[i+1], "-->") {
			continue
		}
		if strings.Contains(lines[i], "-->") {
			out = append(out, reSrtTiming.ReplaceAllString(lines[i], "$1.$2 --> $3.$4"))
			continue
		}
		out = append(out, lines[i])
	}
	res := strings.Join(out, "\n")
	return reMultiBlank.ReplaceAllString(res, "\n\n")
}

func assToVTT(ass string) string {
	lines := strings.Split(ass, "\n")
	inEvents := false
	startIdx, endIdx, textIdx := -1, -1, -1
	numFields := 0

	var cues []string
	for _, rawLine := range lines {
		line := strings.TrimSpace(rawLine)
		if line == "" || strings.HasPrefix(line, ";") {
			continue
		}
		if strings.HasPrefix(line, "[") && strings.HasSuffix(line, "]") {
			inEvents = strings.EqualFold(line, "[Events]")
			continue
		}
		if !inEvents {
			continue
		}
		if strings.HasPrefix(strings.ToLower(line), "format:") {
			rawFields := strings.Split(line[len("format:"):], ",")
			numFields = len(rawFields)
			for idx, f := range rawFields {
				switch strings.ToLower(strings.TrimSpace(f)) {
				case "start":
					startIdx = idx
				case "end":
					endIdx = idx
				case "text":
					textIdx = idx
				}
			}
			continue
		}
		if strings.HasPrefix(strings.ToLower(line), "dialogue:") && startIdx >= 0 && endIdx >= 0 && textIdx >= 0 && numFields > 0 {
			payload := strings.TrimSpace(line[len("dialogue:"):])
			cols := strings.SplitN(payload, ",", numFields)
			if len(cols) <= textIdx || len(cols) <= startIdx || len(cols) <= endIdx {
				continue
			}
			startVTT := formatAssTimestamp(cols[startIdx])
			endVTT := formatAssTimestamp(cols[endIdx])
			txt := cols[textIdx]
			txt = reAssTag.ReplaceAllString(txt, "")
			txt = strings.ReplaceAll(txt, `\N`, "\n")
			txt = strings.ReplaceAll(txt, `\n`, "\n")
			txt = strings.ReplaceAll(txt, `\h`, " ")
			txt = strings.TrimSpace(txt)
			if startVTT == "" || endVTT == "" || txt == "" {
				continue
			}
			cues = append(cues, fmt.Sprintf("%s --> %s\n%s", startVTT, endVTT, txt))
		}
	}

	if len(cues) == 0 {
		return "WEBVTT\n\n"
	}
	return "WEBVTT\n\n" + strings.Join(cues, "\n\n") + "\n"
}

// formatAssTimestamp converts "0:01:23.45" into "00:01:23.450".
func formatAssTimestamp(raw string) string {
	s := strings.TrimSpace(raw)
	parts := strings.Split(s, ":")
	if len(parts) != 3 {
		return ""
	}
	h, err1 := strconv.Atoi(parts[0])
	m, err2 := strconv.Atoi(parts[1])
	secParts := strings.SplitN(parts[2], ".", 2)
	sec, err3 := strconv.Atoi(secParts[0])
	if err1 != nil || err2 != nil || err3 != nil {
		return ""
	}
	ms := 0
	if len(secParts) == 2 {
		frac := secParts[1]
		if len(frac) == 1 {
			frac += "00"
		} else if len(frac) == 2 {
			frac += "0"
		} else if len(frac) > 3 {
			frac = frac[:3]
		}
		ms, _ = strconv.Atoi(frac)
	}
	return fmt.Sprintf("%02d:%02d:%02d.%03d", h, m, sec, ms)
}

func ServeSubtitle(w http.ResponseWriter, r *http.Request, drv storage.Driver, entry storage.Entry, format string) {
	rr, err := drv.OpenRange(r.Context(), entry, 0, nil, false)
	if err != nil {
		writeStorageHTTPError(w, err)
		return
	}
	defer rr.Body.Close()

	raw, err := io.ReadAll(io.LimitReader(rr.Body, 16*1024*1024))
	if err != nil {
		writeStorageHTTPError(w, err)
		return
	}

	utf8Text := DecodeSubtitleToUTF8(raw)
	ext := storage.ExtLower(entry.Name)
	if strings.EqualFold(format, "raw") {
		w.Header().Set("Content-Type", ContentTypeForExt(ext))
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusOK)
		_, _ = io.WriteString(w, utf8Text)
		return
	}

	vtt := ConvertSubtitleToVTT(utf8Text, ext)
	w.Header().Set("Content-Type", "text/vtt; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.WriteHeader(http.StatusOK)
	_, _ = io.WriteString(w, vtt)
}
