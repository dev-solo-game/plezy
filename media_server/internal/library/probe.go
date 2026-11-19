package library

import (
	"bytes"
	"encoding/binary"
	"math"
	"strings"

	"plezy/media_server/internal/db"
)

type ProbeRangeReader func(start int64, length int64) ([]byte, error)

type ProbedMedia struct {
	Container   string
	DurationMs  *int64
	BitrateKbps *int
	Streams     []db.ProbedStream
}

func (p ProbedMedia) FirstVideo() *db.ProbedStream {
	for i := range p.Streams {
		if p.Streams[i].Kind == "video" {
			return &p.Streams[i]
		}
	}
	return nil
}

const (
	probeWindowSize  int64 = 512 * 1024
	probeMaxElement  int64 = 32 * 1024 * 1024
)

type probeWindow struct {
	start int64
	data  []byte
}

type mediaProbe struct {
	read    ProbeRangeReader
	size    int64
	windows []probeWindow
}

func ProbeMedia(extension string, size int64, read ProbeRangeReader) (ProbedMedia, error) {
	ext := strings.ToLower(strings.TrimPrefix(extension, "."))
	if size <= 0 {
		return ProbedMedia{Container: ext}, nil
	}
	p := &mediaProbe{read: read, size: size}
	head, err := p.bytes(0, 12)
	if err != nil {
		return ProbedMedia{Container: ext}, err
	}
	if len(head) >= 4 && binary.BigEndian.Uint32(head[:4]) == 0x1A45DFA3 {
		return p.probeMatroska(ext), nil
	}
	if len(head) >= 8 && isMp4Box(string(head[4:8])) {
		return p.probeMp4(ext), nil
	}
	return ProbedMedia{Container: ext}, nil
}

func (p *mediaProbe) bytes(start, length int64) ([]byte, error) {
	if start >= p.size || length <= 0 {
		return nil, nil
	}
	want := length
	if start+want > p.size {
		want = p.size - start
	}
	for _, w := range p.windows {
		endW := w.start + int64(len(w.data))
		if start >= w.start && start+want <= endW {
			off := start - w.start
			return w.data[off : off+want], nil
		}
	}
	fetchLen := want
	win := probeWindowSize
	if p.size-start < win {
		win = p.size - start
	}
	if win > fetchLen {
		fetchLen = win
	}
	fetched, err := p.read(start, fetchLen)
	if err != nil {
		return nil, err
	}
	p.windows = append(p.windows, probeWindow{start: start, data: fetched})
	if int64(len(fetched)) <= want {
		return fetched, nil
	}
	return fetched[:want], nil
}

func (p *mediaProbe) bitrate(durMs *int64) *int {
	if durMs == nil || *durMs <= 0 || p.size <= 0 {
		return nil
	}
	v := int(math.Round(float64(p.size*8) / float64(*durMs)))
	return &v
}

// ─── Matroska / WebM EBML ──────────────────────────────────────────────────

const (
	ebmlIDHeader               = 0x1A45DFA3
	ebmlIDDocType              = 0x4282
	ebmlIDSegment              = 0x18538067
	ebmlIDSeekHead             = 0x114D9B74
	ebmlIDSeek                 = 0x4DBB
	ebmlIDSeekID               = 0x53AB
	ebmlIDSeekPosition         = 0x53AC
	ebmlIDInfo                 = 0x1549A966
	ebmlIDTimestampScale       = 0x2AD7B1
	ebmlIDDuration             = 0x4489
	ebmlIDTracks               = 0x1654AE6B
	ebmlIDCluster              = 0x1F43B675
	ebmlIDTrackEntry           = 0xAE
	ebmlIDTrackType            = 0x83
	ebmlIDCodecID              = 0x86
	ebmlIDName                 = 0x536E
	ebmlIDLanguage             = 0x22B59C
	ebmlIDLanguageBcp47        = 0x22B59D
	ebmlIDFlagDefault          = 0x88
	ebmlIDFlagForced           = 0x55AA
	ebmlIDDefaultDuration      = 0x23E383
	ebmlIDVideo                = 0xE0
	ebmlIDPixelWidth           = 0xB0
	ebmlIDPixelHeight          = 0xBA
	ebmlIDColour               = 0x55B0
	ebmlIDTransfer             = 0x55BA
	ebmlIDBlockAdditionMapping = 0x41E4
	ebmlIDBlockAddIDType       = 0x41E7
	ebmlIDAudio                = 0xE1
	ebmlIDSamplingFrequency    = 0xB5
	ebmlIDChannels             = 0x9F
	ebmlIDBitDepth             = 0x6264
)

type ebmlElem struct {
	id   uint64
	body int64
	size int64
	unk  bool
}

func readVint(b []byte, off int, keepMarker bool) (val uint64, length int, unk bool, ok bool) {
	if off >= len(b) || b[off] == 0 {
		return 0, 0, false, false
	}
	length = 1
	for length <= 8 && (b[off]&(0x80>>(length-1))) == 0 {
		length++
	}
	if length > 8 || off+length > len(b) {
		return 0, 0, false, false
	}
	if keepMarker {
		val = uint64(b[off])
	} else {
		val = uint64(b[off] & (0xFF >> length))
	}
	allOnes := val == uint64(0xFF>>length)
	for i := 1; i < length; i++ {
		val = (val << 8) | uint64(b[off+i])
		if b[off+i] != 0xFF {
			allOnes = false
		}
	}
	return val, length, !keepMarker && allOnes, true
}

func (p *mediaProbe) readElement(off int64) (ebmlElem, bool) {
	b, err := p.bytes(off, 16)
	if err != nil || len(b) < 2 {
		return ebmlElem{}, false
	}
	id, idLen, _, ok := readVint(b, 0, true)
	if !ok {
		return ebmlElem{}, false
	}
	sz, szLen, unk, ok := readVint(b, idLen, false)
	if !ok {
		return ebmlElem{}, false
	}
	return ebmlElem{
		id:   id,
		body: off + int64(idLen) + int64(szLen),
		size: int64(sz),
		unk:  unk,
	}, true
}

type ebmlChild struct {
	id   uint64
	data []byte
}

func ebmlChildren(b []byte) []ebmlChild {
	var out []ebmlChild
	off := 0
	for off < len(b) {
		id, idLen, _, ok := readVint(b, off, true)
		if !ok {
			break
		}
		sz, szLen, unk, ok := readVint(b, off+idLen, false)
		if !ok {
			break
		}
		start := off + idLen + szLen
		end := len(b)
		if !unk && int64(start)+int64(sz) < int64(end) {
			end = start + int(sz)
		}
		if start > len(b) || end < start {
			break
		}
		out = append(out, ebmlChild{id: id, data: b[start:end]})
		off = end
	}
	return out
}

func ebmlUint(b []byte) uint64 {
	var v uint64
	for _, by := range b {
		v = (v << 8) | uint64(by)
	}
	return v
}

func ebmlFloat(b []byte) (float64, bool) {
	switch len(b) {
	case 4:
		bits := binary.BigEndian.Uint32(b)
		return float64(math.Float32frombits(bits)), true
	case 8:
		bits := binary.BigEndian.Uint64(b)
		return math.Float64frombits(bits), true
	default:
		return 0, false
	}
}

func ebmlString(b []byte) string {
	if idx := bytes.IndexByte(b, 0); idx >= 0 {
		b = b[:idx]
	}
	return string(b)
}

func (p *mediaProbe) probeMatroska(ext string) ProbedMedia {
	hdr, ok := p.readElement(0)
	if !ok || hdr.id != ebmlIDHeader || hdr.unk {
		return ProbedMedia{Container: ext}
	}
	docType := "matroska"
	if hdrBytes, err := p.bytes(hdr.body, hdr.size); err == nil {
		for _, ch := range ebmlChildren(hdrBytes) {
			if ch.id == ebmlIDDocType {
				docType = ebmlString(ch.data)
			}
		}
	}
	container := "mkv"
	if docType == "webm" {
		container = "webm"
	}

	seg, ok := p.readElement(hdr.body + hdr.size)
	if !ok || seg.id != ebmlIDSegment {
		return ProbedMedia{Container: container}
	}
	segEnd := p.size
	if !seg.unk && seg.body+seg.size < segEnd {
		segEnd = seg.body + seg.size
	}

	var info, tracks []byte
	seekTargets := make(map[uint64]int64)

	readBody := func(e ebmlElem) []byte {
		if e.unk || e.size > probeMaxElement {
			return nil
		}
		b, err := p.bytes(e.body, e.size)
		if err != nil {
			return nil
		}
		return b
	}

	off := seg.body
	for step := 0; step < 64 && off < segEnd && (info == nil || tracks == nil); step++ {
		e, ok := p.readElement(off)
		if !ok || e.id == ebmlIDCluster || e.unk {
			break
		}
		switch e.id {
		case ebmlIDInfo:
			info = readBody(e)
		case ebmlIDTracks:
			tracks = readBody(e)
		case ebmlIDSeekHead:
			if sh := readBody(e); sh != nil {
				for _, ch := range ebmlChildren(sh) {
					if ch.id != ebmlIDSeek {
						continue
					}
					var target uint64
					var pos int64
					var hasT, hasP bool
					for _, fld := range ebmlChildren(ch.data) {
						if fld.id == ebmlIDSeekID {
							target = ebmlUint(fld.data)
							hasT = true
						} else if fld.id == ebmlIDSeekPosition {
							pos = int64(ebmlUint(fld.data))
							hasP = true
						}
					}
					if hasT && hasP {
						seekTargets[target] = seg.body + pos
					}
				}
			}
		}
		off = e.body + e.size
	}

	seekTo := func(wanted uint64) []byte {
		at, ok := seekTargets[wanted]
		if !ok {
			return nil
		}
		e, ok := p.readElement(at)
		if !ok || e.id != wanted {
			return nil
		}
		return readBody(e)
	}
	if info == nil {
		info = seekTo(ebmlIDInfo)
	}
	if tracks == nil {
		tracks = seekTo(ebmlIDTracks)
	}

	var durationMs *int64
	if info != nil {
		scale := uint64(1000000)
		var dur float64
		var hasDur bool
		for _, ch := range ebmlChildren(info) {
			if ch.id == ebmlIDTimestampScale {
				scale = ebmlUint(ch.data)
			} else if ch.id == ebmlIDDuration {
				dur, hasDur = ebmlFloat(ch.data)
			}
		}
		if hasDur {
			v := int64(math.Round(dur * float64(scale) / 1000000.0))
			durationMs = &v
		}
	}

	var streams []db.ProbedStream
	if tracks != nil {
		for _, ch := range ebmlChildren(tracks) {
			if ch.id != ebmlIDTrackEntry {
				continue
			}
			if st := matroskaTrack(ch.data, len(streams)); st != nil {
				streams = append(streams, *st)
			}
		}
	}

	return ProbedMedia{
		Container:   container,
		DurationMs:  durationMs,
		BitrateKbps: p.bitrate(durationMs),
		Streams:     streams,
	}
}

func matroskaTrack(entry []byte, index int) *db.ProbedStream {
	var trackType uint64
	var codecID, name, bcp47, hdr string
	lang := "eng"
	isDefault := true
	isForced := false
	var frameNs uint64
	var width, height, channels, sampleRate, bitDepth int

	for _, ch := range ebmlChildren(entry) {
		switch ch.id {
		case ebmlIDTrackType:
			trackType = ebmlUint(ch.data)
		case ebmlIDCodecID:
			codecID = ebmlString(ch.data)
		case ebmlIDName:
			name = ebmlString(ch.data)
		case ebmlIDLanguage:
			lang = ebmlString(ch.data)
		case ebmlIDLanguageBcp47:
			bcp47 = ebmlString(ch.data)
		case ebmlIDFlagDefault:
			isDefault = ebmlUint(ch.data) != 0
		case ebmlIDFlagForced:
			isForced = ebmlUint(ch.data) != 0
		case ebmlIDDefaultDuration:
			frameNs = ebmlUint(ch.data)
		case ebmlIDBlockAdditionMapping:
			for _, f := range ebmlChildren(ch.data) {
				if f.id == ebmlIDBlockAddIDType {
					v := ebmlUint(f.data)
					if v == 0x64766343 || v == 0x64767643 {
						hdr = "dolbyVision"
					}
				}
			}
		case ebmlIDVideo:
			for _, f := range ebmlChildren(ch.data) {
				switch f.id {
				case ebmlIDPixelWidth:
					width = int(ebmlUint(f.data))
				case ebmlIDPixelHeight:
					height = int(ebmlUint(f.data))
				case ebmlIDColour:
					for _, col := range ebmlChildren(f.data) {
						if col.id == ebmlIDTransfer && hdr == "" {
							hdr = hdrFromTransfer(int(ebmlUint(col.data)))
						}
					}
				}
			}
		case ebmlIDAudio:
			for _, f := range ebmlChildren(ch.data) {
				switch f.id {
				case ebmlIDSamplingFrequency:
					if sr, ok := ebmlFloat(f.data); ok {
						sampleRate = int(math.Round(sr))
					}
				case ebmlIDChannels:
					channels = int(ebmlUint(f.data))
				case ebmlIDBitDepth:
					bitDepth = int(ebmlUint(f.data))
				}
			}
		}
	}

	var kind string
	switch trackType {
	case 1:
		kind = "video"
	case 2:
		kind = "audio"
	case 17:
		kind = "subtitle"
	default:
		return nil
	}

	effLang := lang
	if bcp47 != "" {
		effLang = bcp47
	}
	if effLang == "und" {
		effLang = ""
	}
	var fps float64
	if kind == "video" && frameNs > 0 {
		fps = math.Round((1e9/float64(frameNs))*1000) / 1000
	}
	if kind != "video" {
		hdr = ""
	}

	return &db.ProbedStream{
		Kind:       kind,
		Index:      index,
		Codec:      matroskaCodec(codecID),
		Language:   effLang,
		Title:      name,
		Default:    isDefault,
		Forced:     isForced,
		Width:      width,
		Height:     height,
		FrameRate:  fps,
		HDR:        hdr,
		Channels:   channels,
		SampleRate: sampleRate,
		BitDepth:   bitDepth,
	}
}

func matroskaCodec(id string) string {
	if strings.HasPrefix(id, "A_AAC") {
		return "aac"
	}
	if strings.HasPrefix(id, "A_DTS") {
		return "dts"
	}
	if strings.HasPrefix(id, "A_PCM") {
		return "pcm"
	}
	switch id {
	case "V_MPEG4/ISO/AVC":
		return "h264"
	case "V_MPEGH/ISO/HEVC":
		return "hevc"
	case "V_AV1":
		return "av1"
	case "V_VP9":
		return "vp9"
	case "V_VP8":
		return "vp8"
	case "V_MPEG2":
		return "mpeg2video"
	case "V_MPEG4/ISO/ASP", "V_MPEG4/ISO/SP":
		return "mpeg4"
	case "A_AC3":
		return "ac3"
	case "A_EAC3":
		return "eac3"
	case "A_TRUEHD":
		return "truehd"
	case "A_FLAC":
		return "flac"
	case "A_OPUS":
		return "opus"
	case "A_VORBIS":
		return "vorbis"
	case "A_MPEG/L3":
		return "mp3"
	case "A_MPEG/L2":
		return "mp2"
	case "S_TEXT/UTF8":
		return "subrip"
	case "S_TEXT/ASS", "S_ASS":
		return "ass"
	case "S_TEXT/SSA", "S_SSA":
		return "ssa"
	case "S_TEXT/WEBVTT":
		return "webvtt"
	case "S_HDMV/PGS":
		return "hdmv_pgs_subtitle"
	case "S_VOBSUB":
		return "dvd_subtitle"
	default:
		return id
	}
}

func hdrFromTransfer(transfer int) string {
	switch transfer {
	case 16:
		return "hdr10"
	case 18:
		return "hlg"
	default:
		return ""
	}
}

// ─── MP4 / MOV ─────────────────────────────────────────────────────────────

func isMp4Box(t string) bool {
	switch t {
	case "ftyp", "moov", "mdat", "free", "skip", "wide", "pnot", "uuid":
		return true
	default:
		return false
	}
}

type mp4Box struct {
	boxType string
	data    []byte
}

func mp4Boxes(b []byte, from int) []mp4Box {
	var out []mp4Box
	o := from
	for o+8 <= len(b) {
		sz := int64(binary.BigEndian.Uint32(b[o : o+4]))
		bt := string(b[o+4 : o+8])
		hdr := 8
		if sz == 1 && o+16 <= len(b) {
			sz = int64(binary.BigEndian.Uint64(b[o+8 : o+16]))
			hdr = 16
		} else if sz == 0 {
			sz = int64(len(b) - o)
		}
		if sz < int64(hdr) || int64(o)+sz > int64(len(b)) {
			break
		}
		out = append(out, mp4Box{boxType: bt, data: b[o+hdr : int64(o)+sz]})
		o += int(sz)
	}
	return out
}

func findMp4Box(b []byte, path string) []byte {
	cur := b
	for _, seg := range strings.Split(path, "/") {
		var next []byte
		for _, box := range mp4Boxes(cur, 0) {
			if box.boxType == seg {
				next = box.data
				break
			}
		}
		if next == nil {
			return nil
		}
		cur = next
	}
	return cur
}

func (p *mediaProbe) probeMp4(ext string) ProbedMedia {
	container := "mp4"
	if ext == "mov" {
		container = "mov"
	}
	var moov []byte
	var off int64
	for step := 0; step < 64 && off+8 <= p.size; step++ {
		h, err := p.bytes(off, 16)
		if err != nil || len(h) < 8 {
			break
		}
		sz := int64(binary.BigEndian.Uint32(h[:4]))
		bt := string(h[4:8])
		hdr := int64(8)
		if sz == 1 {
			if len(h) < 16 {
				break
			}
			sz = int64(binary.BigEndian.Uint64(h[8:16]))
			hdr = 16
		} else if sz == 0 {
			sz = p.size - off
		}
		if sz < hdr {
			break
		}
		if bt == "ftyp" && len(h) >= 12 && string(h[8:12]) == "qt  " {
			container = "mov"
		}
		if bt == "moov" {
			if sz > probeMaxElement {
				break
			}
			moov, _ = p.bytes(off+hdr, sz-hdr)
			break
		}
		off += sz
	}
	if moov == nil {
		return ProbedMedia{Container: container}
	}

	var durationMs *int64
	var streams []db.ProbedStream
	for _, box := range mp4Boxes(moov, 0) {
		if box.boxType == "mvhd" {
			durationMs = mp4Duration(box.data, 12, 16, 20)
		} else if box.boxType == "trak" {
			if st := mp4Track(box.data, len(streams)); st != nil {
				streams = append(streams, *st)
			}
		}
	}
	return ProbedMedia{
		Container:   container,
		DurationMs:  durationMs,
		BitrateKbps: p.bitrate(durationMs),
		Streams:     streams,
	}
}

func mp4Duration(b []byte, tsAt, durAt, v1TsAt int) *int64 {
	if len(b) == 0 {
		return nil
	}
	v1 := b[0] == 1
	tsOff := tsAt
	need := 8
	if v1 {
		tsOff = v1TsAt
		need = 12
	}
	if len(b) < tsOff+need {
		return nil
	}
	ts := uint64(binary.BigEndian.Uint32(b[tsOff : tsOff+4]))
	var dur uint64
	if v1 {
		dur = binary.BigEndian.Uint64(b[tsOff+4 : tsOff+12])
	} else {
		dur = uint64(binary.BigEndian.Uint32(b[durAt : durAt+4]))
	}
	if ts == 0 || dur == 0 || dur == 0xFFFFFFFF {
		return nil
	}
	v := int64(math.Round(float64(dur) * 1000.0 / float64(ts)))
	return &v
}

func mp4Track(trak []byte, index int) *db.ProbedStream {
	mdia := findMp4Box(trak, "mdia")
	if mdia == nil {
		return nil
	}
	hdlr := findMp4Box(mdia, "hdlr")
	handler := ""
	if len(hdlr) >= 12 {
		handler = string(hdlr[8:12])
	}
	var kind string
	switch handler {
	case "vide":
		kind = "video"
	case "soun":
		kind = "audio"
	case "sbtl", "subt", "text", "clcp":
		kind = "subtitle"
	default:
		return nil
	}

	var lang string
	var timescale uint32
	if mdhd := findMp4Box(mdia, "mdhd"); len(mdhd) > 0 {
		v1 := mdhd[0] == 1
		tsOff, langOff := 12, 20
		if v1 {
			tsOff, langOff = 20, 32
		}
		if len(mdhd) >= tsOff+4 {
			timescale = binary.BigEndian.Uint32(mdhd[tsOff : tsOff+4])
		}
		if len(mdhd) >= langOff+2 {
			lang = mp4Language(binary.BigEndian.Uint16(mdhd[langOff : langOff+2]))
		}
	}

	isDefault := true
	if tkhd := findMp4Box(trak, "tkhd"); len(tkhd) >= 4 {
		isDefault = (tkhd[3] & 0x1) != 0
	}

	var codec, hdr string
	var width, height, channels, sampleRate, bitDepth int
	stbl := findMp4Box(mdia, "minf/stbl")
	if stbl != nil {
		if stsd := findMp4Box(stbl, "stsd"); len(stsd) >= 16 {
			entries := mp4Boxes(stsd, 8)
			if len(entries) > 0 {
				fourcc := entries[0].boxType
				entry := entries[0].data
				codec = mp4Codec(fourcc)
				if strings.HasPrefix(fourcc, "dv") {
					hdr = "dolbyVision"
				}
				if kind == "video" && len(entry) >= 78 {
					width = int(binary.BigEndian.Uint16(entry[24:26]))
					height = int(binary.BigEndian.Uint16(entry[26:28]))
					for _, ch := range mp4Boxes(entry, 78) {
						if ch.boxType == "dvcC" || ch.boxType == "dvvC" {
							hdr = "dolbyVision"
						}
						if ch.boxType == "colr" && len(ch.data) >= 8 && string(ch.data[:4]) == "nclx" && hdr == "" {
							hdr = hdrFromTransfer(int(binary.BigEndian.Uint16(ch.data[6:8])))
						}
					}
				}
				if kind == "audio" && len(entry) >= 28 {
					channels = int(binary.BigEndian.Uint16(entry[16:18]))
					bitDepth = int(binary.BigEndian.Uint16(entry[18:20]))
					sampleRate = int(binary.BigEndian.Uint32(entry[24:28]) >> 16)
					if bitDepth == 16 && codec != "pcm" {
						bitDepth = 0
					}
				}
			}
		}
	}

	var fps float64
	if kind == "video" && stbl != nil && timescale > 0 {
		if stts := findMp4Box(stbl, "stts"); len(stts) >= 16 {
			delta := binary.BigEndian.Uint32(stts[12:16])
			if delta > 0 {
				fps = math.Round((float64(timescale)/float64(delta))*1000) / 1000
			}
		}
	}
	if kind != "video" {
		hdr = ""
	}

	return &db.ProbedStream{
		Kind:       kind,
		Index:      index,
		Codec:      codec,
		Language:   lang,
		Default:    isDefault,
		Width:      width,
		Height:     height,
		FrameRate:  fps,
		HDR:        hdr,
		Channels:   channels,
		SampleRate: sampleRate,
		BitDepth:   bitDepth,
	}
}

func mp4Language(packed uint16) string {
	if packed == 0 || packed == 0x7FFF {
		return ""
	}
	b := [3]byte{
		byte(((packed >> 10) & 0x1F) + 0x60),
		byte(((packed >> 5) & 0x1F) + 0x60),
		byte((packed & 0x1F) + 0x60),
	}
	for _, c := range b {
		if c < 'a' || c > 'z' {
			return ""
		}
	}
	code := string(b[:])
	if code == "und" {
		return ""
	}
	return code
}

func mp4Codec(fourcc string) string {
	switch fourcc {
	case "avc1", "avc3", "dva1", "dvav":
		return "h264"
	case "hvc1", "hev1", "dvh1", "dvhe":
		return "hevc"
	case "av01":
		return "av1"
	case "vp09":
		return "vp9"
	case "mp4v":
		return "mpeg4"
	case "apcn", "apch", "apcs", "apco", "ap4h":
		return "prores"
	case "mp4a":
		return "aac"
	case "ac-3":
		return "ac3"
	case "ec-3":
		return "eac3"
	case "Opus":
		return "opus"
	case "fLaC":
		return "flac"
	case "alac":
		return "alac"
	case "dtsc", "dtsh", "dtsl", "dtse":
		return "dts"
	case "mlpa":
		return "truehd"
	case ".mp3":
		return "mp3"
	case "lpcm", "sowt", "twos", "in24", "in32", "fl32":
		return "pcm"
	case "tx3g":
		return "mov_text"
	case "wvtt":
		return "webvtt"
	case "c608":
		return "eia_608"
	default:
		return strings.TrimSpace(fourcc)
	}
}
