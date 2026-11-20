package vault

import (
	"bytes"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVaultSealOpenAndPersistence(t *testing.T) {
	dir := t.TempDir()
	v1, err := Open(dir, "")
	if err != nil {
		t.Fatalf("open vault: %v", err)
	}
	if _, err := os.Stat(filepath.Join(dir, "master.key")); err != nil {
		t.Fatalf("master.key not persisted: %v", err)
	}

	secret := "cookie=__pus=abc123; __puus=xyz789"
	sealed, err := v1.Seal(secret)
	if err != nil {
		t.Fatalf("seal: %v", err)
	}
	if !strings.HasPrefix(sealed, sealedPrefix) {
		t.Fatalf("unexpected prefix: %q", sealed)
	}
	if sealed == secret {
		t.Fatal("sealed payload must not equal plaintext")
	}

	// Reopen from disk and decrypt.
	v2, err := Open(dir, "")
	if err != nil {
		t.Fatalf("reopen vault: %v", err)
	}
	opened, err := v2.Open(sealed)
	if err != nil {
		t.Fatalf("open sealed: %v", err)
	}
	if opened != secret {
		t.Fatalf("got %q want %q", opened, secret)
	}
	if !bytes.Equal(v1.StreamSigningKey(), v2.StreamSigningKey()) {
		t.Fatal("stream signing key drifted across reopen")
	}
}

func TestVaultRejectsTamperedCiphertext(t *testing.T) {
	v, err := Open(t.TempDir(), "custom-env-passphrase")
	if err != nil {
		t.Fatalf("open: %v", err)
	}
	sealed, err := v.Seal("super-secret-password")
	if err != nil {
		t.Fatalf("seal: %v", err)
	}

	// Flip last character.
	tampered := sealed[:len(sealed)-1]
	if sealed[len(sealed)-1] == 'A' {
		tampered += "B"
	} else {
		tampered += "A"
	}
	if _, err := v.Open(tampered); !errors.Is(err, ErrInvalidCiphertext) {
		t.Fatalf("expected ErrInvalidCiphertext, got %v", err)
	}
	if _, err := v.Open("plain-unsealed-text"); !errors.Is(err, ErrInvalidCiphertext) {
		t.Fatalf("expected ErrInvalidCiphertext for unsealed text, got %v", err)
	}
}
