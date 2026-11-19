package quark

import (
	"crypto/md5"
	"crypto/rand"
	"encoding/base64"
	"encoding/binary"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
)

type PcDevice struct {
	Utdid   string `json:"utdid"`
	Machine string `json:"machine"`
}

func GeneratePcDevice() PcDevice {
	var b [18]byte
	binary.BigEndian.PutUint32(b[:4], uint32(time.Now().Unix()))
	_, _ = rand.Read(b[4:])
	b[8] = 0x03
	b[9] = 0x00
	suffix := strings.ToUpper(strings.ReplaceAll(uuid.NewString(), "-", "")[:6])
	return PcDevice{
		Utdid:   base64.StdEncoding.EncodeToString(b[:]),
		Machine: "DESKTOP-" + suffix,
	}
}

type PcSession struct {
	Ticket   string   `json:"token"`
	UID      string   `json:"uid"`
	Nickname string   `json:"nickname"`
	Device   PcDevice `json:"device"`
}

func ParsePcSession(secret string) PcSession {
	trimmed := strings.TrimSpace(secret)
	if strings.HasPrefix(trimmed, "{") {
		var raw map[string]any
		if json.Unmarshal([]byte(trimmed), &raw) == nil {
			s := PcSession{
				Ticket:   strVal(raw["token"]),
				UID:      strVal(raw["uid"]),
				Nickname: strVal(raw["nickname"]),
			}
			ut := strVal(raw["utdid"])
			mach := strVal(raw["machine"])
			if ut != "" && mach != "" {
				s.Device = PcDevice{Utdid: ut, Machine: mach}
			} else {
				s.Device = GeneratePcDevice()
			}
			return s
		}
	}

	between := func(after, before string) string {
		start := strings.Index(trimmed, after)
		if start < 0 {
			return ""
		}
		from := start + len(after)
		if before == "" {
			return trimmed[from:]
		}
		end := strings.Index(trimmed[from:], before)
		if end < 0 {
			return trimmed[from:]
		}
		return trimmed[from : from+end]
	}

	return PcSession{
		Ticket:   between("token=", "&uid="),
		UID:      between("&uid=", "&nickname="),
		Nickname: between("&nickname=", ""),
		Device:   GeneratePcDevice(),
	}
}

func strVal(v any) string {
	if v == nil {
		return ""
	}
	if s, ok := v.(string); ok {
		return s
	}
	return fmt.Sprintf("%v", v)
}

func (s *PcSession) IsValid() bool {
	return s.Ticket != "" && s.UID != ""
}

func (s *PcSession) Serialize() string {
	raw, _ := json.Marshal(map[string]string{
		"token":    s.Ticket,
		"uid":      s.UID,
		"nickname": s.Nickname,
		"utdid":    s.Device.Utdid,
		"machine":  s.Device.Machine,
	})
	return string(raw)
}

func (s *PcSession) BusinessHeaders(w *Wsg, now time.Time) (map[string]string, error) {
	vcode := strconv.FormatInt(now.UnixMilli(), 10)
	if len(vcode) < 5 {
		vcode = "00000" + vcode
	}
	signPlain := vcode[:5] + s.Ticket + s.UID + s.Nickname + vcode[len(vcode)-1:]
	signSum := md5.Sum([]byte(signPlain)) //nolint:gosec
	signHex := hex.EncodeToString(signSum[:])

	kpsPlain := fmt.Sprintf("token=%s&uid=%s&nickname=%s", s.Ticket, s.UID, s.Nickname)
	kpsEnc, err := w.Encode(kpsPlain)
	if err != nil {
		return nil, err
	}
	signEnc, err := w.Encode(signHex)
	if err != nil {
		return nil, err
	}
	return map[string]string{
		"x-u-vcode":   vcode,
		"x-u-kps-wg":  kpsEnc,
		"x-u-sign-wg": signEnc,
	}, nil
}

func (s *PcSession) KuusCookie(w *Wsg, now time.Time) (string, error) {
	secs := now.Unix()
	enc, err := w.Encode(fmt.Sprintf("ucid=%s&st=%s&time=%d", s.UID, s.Ticket, secs))
	if err != nil {
		return "", err
	}
	return "__kuus=" + enc, nil
}

func (s *PcSession) CommonQuery(w *Wsg) (map[string]string, error) {
	utEnc, err := w.Encode(s.Device.Utdid)
	if err != nil {
		return nil, err
	}
	return map[string]string{
		"uc_param_str": "utfrpr",
		"device_model": "Desktop",
		"pr":           "qk_clouddrive",
		"fr":           "win",
		"sys":          "win32",
		"ve":           "7.5.0.825",
		"ut":           utEnc,
	}, nil
}
