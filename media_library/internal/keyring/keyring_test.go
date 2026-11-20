package keyring

import (
	"testing"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/vault"
)

func seedTestHousehold(t *testing.T, store *db.Store, id string) {
	t.Helper()
	now := store.NowMs()
	if _, err := store.DB().Exec(`INSERT INTO accounts(id, username, password_salt, password_hash, created_at, updated_at) VALUES (?, ?, 's', 'h', ?, ?)`, "acc-"+id, "user-"+id, now, now); err != nil {
		t.Fatal(err)
	}
	if _, err := store.DB().Exec(`INSERT INTO households(id, owner_account_id, name, created_at, updated_at) VALUES (?, ?, 'Home', ?, ?)`, id, "acc-"+id, now, now); err != nil {
		t.Fatal(err)
	}
}

func TestKeyringLifecycleAndTenantIsolation(t *testing.T) {
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dir, v)
	if err != nil {
		t.Fatal(err)
	}
	defer store.Close()

	seedTestHousehold(t, store, "hh1")
	seedTestHousehold(t, store, "hh2")

	// Reject invalid wrap params
	if err := ValidateWrap(KeyWrap{
		WrapType:      "invalid",
		SubjectID:     "sub",
		KdfAlg:        KdfAlgArgon2id,
		KdfSalt:       "salt",
		KdfParamsJSON: `{}`,
		WrappedHK:     "cipher",
	}); err == nil {
		t.Fatal("expected error for unsupported wrap_type")
	}
	if err := ValidateWrap(KeyWrap{
		WrapType:      WrapAccountPassword,
		SubjectID:     "acc-hh1",
		KdfAlg:        KdfAlgPBKDF2,
		KdfSalt:       "salt",
		KdfParamsJSON: `not-json`,
		WrappedHK:     "cipher",
	}); err == nil {
		t.Fatal("expected error for invalid kdf_params_json")
	}

	if err := UpsertWrap(store, KeyWrap{
		HouseholdID:   "hh1",
		WrapType:      WrapAccountPassword,
		SubjectID:     "acc-hh1",
		KdfAlg:        KdfAlgArgon2id,
		KdfSalt:       "c2FsdA==",
		KdfParamsJSON: `{"m":16384,"t":2,"p":1}`,
		WrappedHK:     "enc:hk:v1:abc",
		KeyEpoch:      1,
	}); err != nil {
		t.Fatalf("UpsertWrap account_password: %v", err)
	}
	if err := UpsertWrap(store, KeyWrap{
		HouseholdID:   "hh1",
		WrapType:      WrapRecoveryCode,
		SubjectID:     "acc-hh1",
		KdfAlg:        KdfAlgPBKDF2,
		KdfSalt:       "cmVj",
		KdfParamsJSON: `{"iterations":600000}`,
		WrappedHK:     "enc:hk:v1:rec",
		KeyEpoch:      1,
	}); err != nil {
		t.Fatalf("UpsertWrap recovery_code: %v", err)
	}
	if err := UpsertWrap(store, KeyWrap{
		HouseholdID:   "hh2",
		WrapType:      WrapAccountPassword,
		SubjectID:     "acc-hh2",
		KdfAlg:        KdfAlgArgon2id,
		KdfSalt:       "c2FsdDI=",
		KdfParamsJSON: `{"m":16384,"t":2,"p":1}`,
		WrappedHK:     "enc:hk:v1:other",
		KeyEpoch:      2,
	}); err != nil {
		t.Fatalf("UpsertWrap hh2: %v", err)
	}

	// Upsert updates existing wrap on (household_id, wrap_type, subject_id)
	if err := UpsertWrap(store, KeyWrap{
		HouseholdID:   "hh1",
		WrapType:      WrapAccountPassword,
		SubjectID:     "acc-hh1",
		KdfAlg:        KdfAlgArgon2id,
		KdfSalt:       "bmV3c2FsdA==",
		KdfParamsJSON: `{"m":16384,"t":2,"p":1}`,
		WrappedHK:     "enc:hk:v1:rotated",
		KeyEpoch:      2,
	}); err != nil {
		t.Fatalf("UpsertWrap update: %v", err)
	}

	wraps, err := ListWraps(store, "hh1", nil, "")
	if err != nil || len(wraps) != 2 {
		t.Fatalf("ListWraps hh1 len=%d err=%v", len(wraps), err)
	}
	acctWraps, err := ListWraps(store, "hh1", []string{WrapAccountPassword}, "acc-hh1")
	if err != nil || len(acctWraps) != 1 || acctWraps[0].WrappedHK != "enc:hk:v1:rotated" || acctWraps[0].KeyEpoch != 2 {
		t.Fatalf("unexpected filtered wraps: %+v err=%v", acctWraps, err)
	}

	epoch, err := CurrentEpoch(store, "hh1")
	if err != nil || epoch != 2 {
		t.Fatalf("CurrentEpoch = %d, err = %v, want 2", epoch, err)
	}

	// Deleting hh1 wraps does not touch hh2 wraps
	tx, err := store.DB().Begin()
	if err != nil {
		t.Fatal(err)
	}
	if err := DeleteHouseholdWrapsTx(tx, "hh1"); err != nil {
		t.Fatal(err)
	}
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}

	wrapsAfter, _ := ListWraps(store, "hh1", nil, "")
	hh2Wraps, _ := ListWraps(store, "hh2", nil, "")
	if len(wrapsAfter) != 0 || len(hh2Wraps) != 1 {
		t.Fatalf("unexpected wrap counts after delete: hh1=%d hh2=%d", len(wrapsAfter), len(hh2Wraps))
	}
}
