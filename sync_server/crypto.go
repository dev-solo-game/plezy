package main

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strings"

	"golang.org/x/crypto/argon2"
	"golang.org/x/crypto/hkdf"
)

const masterKeyBackupPrefix = "enc:mk:v1:"

var errInvalidEnvelope = errors.New("invalid encrypted key envelope")

func DefaultKdfParams() KdfParams {
	return KdfParams{
		Algo: "argon2id",
		M:    16384,
		T:    2,
		P:    1,
	}
}

func randomBytes(n int) ([]byte, error) {
	out := make([]byte, n)
	if _, err := rand.Read(out); err != nil {
		return nil, err
	}
	return out, nil
}

// DerivePasswordKeys mirrors lib/library/sync/sync_crypto.dart (SyncCrypto.derivePasswordKeys)
// so accounts created or updated from the Web panel are 100% interoperable with Flutter clients.
func DerivePasswordKeys(password string, salt []byte, params KdfParams) (kek []byte, authVerifier string, err error) {
	if params.M <= 0 {
		params.M = 16384
	}
	if params.T <= 0 {
		params.T = 2
	}
	if params.P <= 0 {
		params.P = 1
	}

	rootKey := argon2.IDKey([]byte(password), salt, uint32(params.T), uint32(params.M), uint8(params.P), 32)

	kekReader := hkdf.New(sha256.New, rootKey, nil, []byte("plezy-sync-kek-v1"))
	kek = make([]byte, 32)
	if _, err := io.ReadFull(kekReader, kek); err != nil {
		return nil, "", fmt.Errorf("derive kek: %w", err)
	}

	authReader := hkdf.New(sha256.New, rootKey, nil, []byte("plezy-sync-auth-v1"))
	authBytes := make([]byte, 32)
	if _, err := io.ReadFull(authReader, authBytes); err != nil {
		return nil, "", fmt.Errorf("derive auth verifier: %w", err)
	}

	return kek, base64.StdEncoding.EncodeToString(authBytes), nil
}

type secretBoxPayload struct {
	N string `json:"n"`
	C string `json:"c"`
	M string `json:"m"`
}

func SealMasterKeyBackup(masterKey, kek []byte) (string, error) {
	block, err := aes.NewCipher(kek)
	if err != nil {
		return "", err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return "", err
	}
	nonce, err := randomBytes(gcm.NonceSize())
	if err != nil {
		return "", err
	}
	sealed := gcm.Seal(nil, nonce, masterKey, nil)
	tagOffset := len(sealed) - gcm.Overhead()
	payload := secretBoxPayload{
		N: base64.StdEncoding.EncodeToString(nonce),
		C: base64.StdEncoding.EncodeToString(sealed[:tagOffset]),
		M: base64.StdEncoding.EncodeToString(sealed[tagOffset:]),
	}
	raw, err := json.Marshal(payload)
	if err != nil {
		return "", err
	}
	return masterKeyBackupPrefix + string(raw), nil
}

func UnsealMasterKeyBackup(envelope string, kek []byte) ([]byte, error) {
	if !strings.HasPrefix(envelope, masterKeyBackupPrefix) {
		return nil, errInvalidEnvelope
	}
	var payload secretBoxPayload
	if err := json.Unmarshal([]byte(strings.TrimPrefix(envelope, masterKeyBackupPrefix)), &payload); err != nil {
		return nil, err
	}
	nonce, err := base64.StdEncoding.DecodeString(payload.N)
	if err != nil {
		return nil, errInvalidEnvelope
	}
	cipherText, err := base64.StdEncoding.DecodeString(payload.C)
	if err != nil {
		return nil, errInvalidEnvelope
	}
	mac, err := base64.StdEncoding.DecodeString(payload.M)
	if err != nil {
		return nil, errInvalidEnvelope
	}
	block, err := aes.NewCipher(kek)
	if err != nil {
		return nil, err
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, err
	}
	combined := append(append([]byte(nil), cipherText...), mac...)
	return gcm.Open(nil, nonce, combined, nil)
}
