package security

import (
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"net"
	"strings"

	"github.com/google/uuid"
	"golang.org/x/crypto/argon2"
)

const (
	argonTime    = 2
	argonMemory  = 19456
	argonThreads = 1
	argonKeyLen  = 32
	saltLen      = 16
)

var ErrInvalidCIDR = errors.New("invalid CIDR or IP address")

func HashSecret(plain string) (saltB64, hashB64 string, err error) {
	salt := make([]byte, saltLen)
	if _, err = rand.Read(salt); err != nil {
		return "", "", fmt.Errorf("generate salt: %w", err)
	}
	saltB64 = base64.RawStdEncoding.EncodeToString(salt)
	derived := argon2.IDKey([]byte(plain), salt, argonTime, argonMemory, argonThreads, argonKeyLen)
	hashB64 = base64.RawStdEncoding.EncodeToString(derived)
	return saltB64, hashB64, nil
}

func VerifySecret(plain, saltB64, expectedHash string) bool {
	if saltB64 == "" || expectedHash == "" {
		return false
	}
	salt, err := base64.RawStdEncoding.DecodeString(saltB64)
	if err != nil {
		return false
	}
	want, err := base64.RawStdEncoding.DecodeString(expectedHash)
	if err != nil {
		return false
	}
	got := argon2.IDKey([]byte(plain), salt, argonTime, argonMemory, argonThreads, uint32(len(want)))
	return subtle.ConstantTimeCompare(got, want) == 1
}

// GenerateOpaqueToken generates a cryptographically random token with the given
// prefix, a UUID tokenID, and its SHA-256 hex digest.
func GenerateOpaqueToken(prefix string) (rawToken, tokenID, tokenHash string, err error) {
	rawBytes := make([]byte, 32)
	if _, err = rand.Read(rawBytes); err != nil {
		return "", "", "", fmt.Errorf("generate token: %w", err)
	}
	rawToken = prefix + base64.RawURLEncoding.EncodeToString(rawBytes)
	tokenID = uuid.NewString()
	tokenHash = HashToken(rawToken)
	return rawToken, tokenID, tokenHash, nil
}

func HashToken(raw string) string {
	sum := sha256.Sum256([]byte(strings.TrimSpace(raw)))
	return hex.EncodeToString(sum[:])
}

func ParseCIDRList(csv string) ([]*net.IPNet, error) {
	trimmed := strings.TrimSpace(csv)
	if trimmed == "" {
		return nil, nil
	}
	parts := strings.Split(trimmed, ",")
	nets := make([]*net.IPNet, 0, len(parts))
	for _, p := range parts {
		item := strings.TrimSpace(p)
		if item == "" {
			continue
		}
		if strings.Contains(item, "/") {
			_, ipNet, err := net.ParseCIDR(item)
			if err != nil {
				return nil, fmt.Errorf("%w: %q", ErrInvalidCIDR, item)
			}
			nets = append(nets, ipNet)
			continue
		}
		ip := net.ParseIP(item)
		if ip == nil {
			return nil, fmt.Errorf("%w: %q", ErrInvalidCIDR, item)
		}
		bits := 128
		if v4 := ip.To4(); v4 != nil {
			ip = v4
			bits = 32
		}
		nets = append(nets, &net.IPNet{
			IP:   ip,
			Mask: net.CIDRMask(bits, bits),
		})
	}
	return nets, nil
}

func IPAllowed(rawIP string, nets []*net.IPNet) bool {
	if len(nets) == 0 {
		return true
	}
	clean := strings.TrimSpace(rawIP)
	if host, _, err := net.SplitHostPort(clean); err == nil {
		clean = host
	}
	ip := net.ParseIP(clean)
	if ip == nil {
		return false
	}
	for _, n := range nets {
		if n.Contains(ip) {
			return true
		}
	}
	return false
}
