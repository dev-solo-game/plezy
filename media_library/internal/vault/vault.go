package vault

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/crypto/hkdf"
)

const sealedPrefix = "enc:v1:"

var (
	ErrInvalidCiphertext = errors.New("invalid encrypted payload")
	ErrKeyLength         = errors.New("master key must be 32 bytes")
)

// Vault seals and opens sensitive credentials using AES-256-GCM backed by a
// persisted 32-byte master key.
type Vault struct {
	masterKey []byte
	streamKey []byte
}

// Open initializes a Vault from envMasterKey (when non-empty) or from
// <dataDir>/master.key, generating a new random key on first boot.
func Open(dataDir, envMasterKey string) (*Vault, error) {
	var key []byte
	if rawEnv := strings.TrimSpace(envMasterKey); rawEnv != "" {
		sum := sha256.Sum256([]byte(rawEnv))
		key = sum[:]
	} else {
		if err := os.MkdirAll(dataDir, 0o755); err != nil {
			return nil, fmt.Errorf("create data dir: %w", err)
		}
		keyPath := filepath.Join(dataDir, "master.key")
		loaded, err := loadOrCreateKeyFile(keyPath)
		if err != nil {
			return nil, err
		}
		key = loaded
	}
	return NewFromKey(key)
}

// NewFromKey builds a Vault from an explicit 32-byte key (primarily for tests).
func NewFromKey(masterKey []byte) (*Vault, error) {
	if len(masterKey) != 32 {
		return nil, ErrKeyLength
	}
	mk := make([]byte, 32)
	copy(mk, masterKey)

	sk := make([]byte, 32)
	reader := hkdf.New(sha256.New, mk, nil, []byte("ttplay-media-stream-token-v1"))
	if _, err := io.ReadFull(reader, sk); err != nil {
		return nil, fmt.Errorf("derive stream key: %w", err)
	}
	return &Vault{
		masterKey: mk,
		streamKey: sk,
	}, nil
}

func loadOrCreateKeyFile(keyPath string) ([]byte, error) {
	data, err := os.ReadFile(keyPath)
	if err == nil {
		trimmed := strings.TrimSpace(string(data))
		if len(trimmed) == 64 {
			if decoded, decErr := hex.DecodeString(trimmed); decErr == nil && len(decoded) == 32 {
				return decoded, nil
			}
		}
		if len(data) == 32 {
			return data, nil
		}
		return nil, fmt.Errorf("corrupted master key file at %s", keyPath)
	}
	if !os.IsNotExist(err) {
		return nil, fmt.Errorf("read master key: %w", err)
	}

	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return nil, fmt.Errorf("generate master key: %w", err)
	}
	if err := os.WriteFile(keyPath, []byte(hex.EncodeToString(key)+"\n"), 0o600); err != nil {
		return nil, fmt.Errorf("write master key: %w", err)
	}
	return key, nil
}

// Seal encrypts plaintext with AES-256-GCM. Empty strings stay empty.
func (v *Vault) Seal(plaintext string) (string, error) {
	if plaintext == "" {
		return "", nil
	}
	block, err := aes.NewCipher(v.masterKey)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return "", err
	}
	sealed := gcm.Seal(nonce, nonce, []byte(plaintext), nil)
	return sealedPrefix + base64.StdEncoding.EncodeToString(sealed), nil
}

// Open decrypts a payload produced by Seal. Empty strings return empty.
func (v *Vault) Open(sealed string) (string, error) {
	if sealed == "" {
		return "", nil
	}
	if !strings.HasPrefix(sealed, sealedPrefix) {
		return "", ErrInvalidCiphertext
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(sealed, sealedPrefix))
	if err != nil {
		return "", ErrInvalidCiphertext
	}
	block, err := aes.NewCipher(v.masterKey)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	if len(raw) < gcm.NonceSize()+gcm.Overhead() {
		return "", ErrInvalidCiphertext
	}
	nonce := raw[:gcm.NonceSize()]
	cipherText := raw[gcm.NonceSize():]
	plain, err := gcm.Open(nil, nonce, cipherText, nil)
	if err != nil {
		return "", ErrInvalidCiphertext
	}
	return string(plain), nil
}

// StreamSigningKey returns a domain-separated 32-byte HMAC key for short-lived
// playback and HLS proxy URLs.
func (v *Vault) StreamSigningKey() []byte {
	out := make([]byte, len(v.streamKey))
	copy(out, v.streamKey)
	return out
}
