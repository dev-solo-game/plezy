package quark

import (
	"bytes"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/md5"
	"crypto/sha1"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strings"
)

const (
	wsgHmacKey  = "C88EAC2B-F07C-4FE2-ABDF-C8F049C46C7B"
	wsgSalt     = "uwRrFVXjBeLMysYN"
	wsgSelector = uint16(0x35e9)
)

type Wsg struct {
	hmacKey []byte
	salt    []byte
	aesKey  []byte
}

func NewWsg() *Wsg {
	hk := []byte(wsgHmacKey)
	md5Hex := hex.EncodeToString(md5Sum(hk))
	aesKey := []byte(md5Hex[:16])
	return &Wsg{
		hmacKey: hk,
		salt:    []byte(wsgSalt),
		aesKey:  aesKey,
	}
}

func md5Sum(b []byte) []byte {
	s := md5.Sum(b) //nolint:gosec
	return s[:]
}

func pkcs7Pad(data []byte, blockSize int) []byte {
	pad := blockSize - (len(data) % blockSize)
	out := make([]byte, len(data)+pad)
	copy(out, data)
	for i := len(data); i < len(out); i++ {
		out[i] = byte(pad)
	}
	return out
}

func pkcs7Unpad(data []byte, blockSize int) ([]byte, error) {
	if len(data) == 0 || len(data)%blockSize != 0 {
		return nil, errors.New("invalid pkcs7 padded length")
	}
	pad := int(data[len(data)-1])
	if pad <= 0 || pad > blockSize || pad > len(data) {
		return nil, errors.New("invalid pkcs7 padding value")
	}
	for i := len(data) - pad; i < len(data); i++ {
		if int(data[i]) != pad {
			return nil, errors.New("corrupted pkcs7 padding")
		}
	}
	return data[:len(data)-pad], nil
}

func (w *Wsg) Encode(plaintext string) (string, error) {
	block, err := aes.NewCipher(w.aesKey)
	if err != nil {
		return "", err
	}
	padded := pkcs7Pad([]byte(plaintext), aes.BlockSize)
	cipherText := make([]byte, len(padded))
	mode := cipher.NewCBCEncrypter(block, w.aesKey)
	mode.CryptBlocks(cipherText, padded)

	buf := make([]byte, 2+len(cipherText))
	buf[0] = byte((wsgSelector >> 8) & 0xff)
	buf[1] = byte(wsgSelector & 0xff)
	copy(buf[2:], cipherText)
	return base64.StdEncoding.EncodeToString(buf), nil
}

func (w *Wsg) Decode(b64 string) ([]byte, error) {
	raw, err := base64.StdEncoding.DecodeString(strings.TrimSpace(b64))
	if err != nil {
		return nil, err
	}
	if len(raw) < 2 || raw[0] != byte((wsgSelector>>8)&0xff) || raw[1] != byte(wsgSelector&0xff) {
		return nil, errors.New("WSG selector mismatch")
	}
	payload := raw[2:]
	if len(payload) == 0 || len(payload)%aes.BlockSize != 0 {
		return nil, errors.New("invalid WSG ciphertext length")
	}
	block, err := aes.NewCipher(w.aesKey)
	if err != nil {
		return nil, err
	}
	plain := make([]byte, len(payload))
	mode := cipher.NewCBCDecrypter(block, w.aesKey)
	mode.CryptBlocks(plain, payload)
	return pkcs7Unpad(plain, aes.BlockSize)
}

func (w *Wsg) DecodeText(b64 string) (string, error) {
	b, err := w.Decode(b64)
	if err != nil {
		return "", err
	}
	return string(b), nil
}

func (w *Wsg) Sign(params map[string]string) string {
	keys := make([]string, 0, len(params))
	for k := range params {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var buf bytes.Buffer
	for _, k := range keys {
		buf.WriteString(k)
		buf.WriteByte('=')
		buf.WriteString(params[k])
	}
	buf.Write(w.salt)

	mac := hmac.New(sha1.New, w.hmacKey) //nolint:gosec
	_, _ = mac.Write(buf.Bytes())
	return fmt.Sprintf("%04x%s", wsgSelector, hex.EncodeToString(mac.Sum(nil)))
}
