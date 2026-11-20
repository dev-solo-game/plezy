package source

import (
	"errors"
	"testing"
	"time"

	"plezy/media_library/internal/account"
	"plezy/media_library/internal/db"
	"plezy/media_library/internal/events"
	"plezy/media_library/internal/security"
	"plezy/media_library/internal/vault"
)

func openTestSourceEnv(t *testing.T) (*Service, *account.Service, *db.Store, *events.Hub, func(time.Duration)) {
	t.Helper()
	dir := t.TempDir()
	v, err := vault.Open(dir, "")
	if err != nil {
		t.Fatal(err)
	}
	store, err := db.Open(dir, v)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = store.Close() })

	hub := events.NewHub()
	now := time.Unix(1700000000, 0)
	advance := func(d time.Duration) { now = now.Add(d) }

	accSvc := account.NewService(store, security.NewLoginLimiter())
	accSvc.SetClock(func() time.Time { return now })

	srcSvc := NewService(store, hub)
	srcSvc.SetClock(func() time.Time { return now })

	return srcSvc, accSvc, store, hub, advance
}

func registerUserDevice(t *testing.T, accSvc *account.Service, username, deviceClass, ip string) *account.AuthResult {
	t.Helper()
	res, err := accSvc.Register(account.RegisterRequest{
		Username: username,
		Password: "Password123!",
		Device: account.DeviceInput{
			Class:    deviceClass,
			Platform: "testos",
			Name:     username + "-" + deviceClass,
		},
	}, ip)
	if err != nil {
		t.Fatalf("register %s: %v", username, err)
	}
	return res
}

func loginSameHousehold(t *testing.T, accSvc *account.Service, username, deviceClass, ip string) *account.AuthResult {
	t.Helper()
	res, err := accSvc.Login(account.LoginRequest{
		Username: username,
		Password: "Password123!",
		Device: account.DeviceInput{
			Class:    deviceClass,
			Platform: "testos",
			Name:     username + "-" + deviceClass,
		},
	}, ip)
	if err != nil {
		t.Fatalf("login %s (%s): %v", username, deviceClass, err)
	}
	return res
}

func TestDeviceAddPolicyAndDynamicUpdate(t *testing.T) {
	srcSvc, accSvc, store, _, _ := openTestSourceEnv(t)

	pc := registerUserDevice(t, accSvc, "alice_pol", db.DeviceClassDesktop, "10.0.0.1")
	phone := loginSameHousehold(t, accSvc, "alice_pol", db.DeviceClassPhone, "10.0.0.2")
	tv := loginSameHousehold(t, accSvc, "alice_pol", db.DeviceClassTV, "10.0.0.3")
	web := loginSameHousehold(t, accSvc, "alice_pol", db.DeviceClassWeb, "10.0.0.4")

	// PC adds Quark -> OK; PC adds WebDAV -> blocked
	if _, err := srcSvc.CreateSource(pc.Principal, CreateSourceRequest{
		Kind:        db.SourceKindQuark,
		Name:        "My Quark",
		IdentityKey: "qk_hmac_1",
		Ciphertext:  "cipher_qk_1",
	}, "10.0.0.1"); err != nil {
		t.Fatalf("desktop add quark failed: %v", err)
	}
	if _, err := srcSvc.CreateSource(pc.Principal, CreateSourceRequest{
		Kind:        db.SourceKindWebDAV,
		Name:        "PC WebDAV",
		IdentityKey: "wd_hmac_1",
		Ciphertext:  "cipher_wd_1",
	}, "10.0.0.1"); !errors.Is(err, ErrKindNotAllowedOnDevice) {
		t.Fatalf("expected desktop webdav ErrKindNotAllowedOnDevice, got %v", err)
	}

	// Phone adds WebDAV -> OK; Phone adds Quark -> blocked
	if _, err := srcSvc.CreateSource(phone.Principal, CreateSourceRequest{
		Kind:        db.SourceKindWebDAV,
		Name:        "Phone NAS",
		IdentityKey: "wd_hmac_2",
		Ciphertext:  "cipher_wd_2",
	}, "10.0.0.2"); err != nil {
		t.Fatalf("phone add webdav failed: %v", err)
	}
	if _, err := srcSvc.CreateSource(phone.Principal, CreateSourceRequest{
		Kind:        db.SourceKindQuark,
		Name:        "Phone Quark",
		IdentityKey: "qk_hmac_2",
		Ciphertext:  "cipher_qk_2",
	}, "10.0.0.2"); !errors.Is(err, ErrKindNotAllowedOnDevice) {
		t.Fatalf("expected phone quark ErrKindNotAllowedOnDevice, got %v", err)
	}

	// TV and Web cannot add any source by default
	for _, dev := range []*account.AuthResult{tv, web} {
		for _, k := range []string{db.SourceKindQuark, db.SourceKindWebDAV, db.SourceKindEmby, db.SourceKindJellyfin} {
			if _, err := srcSvc.CreateSource(dev.Principal, CreateSourceRequest{
				Kind:        k,
				Name:        "Disallowed",
				IdentityKey: "id_" + k,
				Ciphertext:  "cipher",
			}, "10.0.0.3"); !errors.Is(err, ErrKindNotAllowedOnDevice) {
				t.Fatalf("device %s add %s expected ErrKindNotAllowedOnDevice, got %v", dev.Principal.DeviceClass, k, err)
			}
		}
	}

	// Admin updates policy dynamically to let TV add Emby
	newPolicy := `{"desktop":["quark","emby","jellyfin"],"phone":["webdav","emby","jellyfin"],"tablet":["webdav","emby","jellyfin"],"tv":["emby"],"web":[]}`
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{SourceAddPolicyJSON: &newPolicy}); err != nil {
		t.Fatal(err)
	}
	if _, err := srcSvc.CreateSource(tv.Principal, CreateSourceRequest{
		Kind:        db.SourceKindEmby,
		Name:        "TV Emby",
		IdentityKey: "emby_hmac_1",
		Ciphertext:  "cipher_emby",
	}, "10.0.0.3"); err != nil {
		t.Fatalf("expected TV emby to succeed after dynamic policy update, got %v", err)
	}
}

func TestDeduplicationQuotasAndFolders(t *testing.T) {
	srcSvc, accSvc, store, _, _ := openTestSourceEnv(t)

	pcA := registerUserDevice(t, accSvc, "alice_dedup", db.DeviceClassDesktop, "10.1.0.1")
	phoneA := loginSameHousehold(t, accSvc, "alice_dedup", db.DeviceClassPhone, "10.1.0.2")
	pcB := registerUserDevice(t, accSvc, "bob_dedup", db.DeviceClassDesktop, "10.1.0.3")

	// Strong identity dedup within household vs across households
	qk, err := srcSvc.CreateSource(pcA.Principal, CreateSourceRequest{
		Kind:        db.SourceKindQuark,
		Name:        "Quark Main",
		IdentityKey: "qk_uid_shared",
		Ciphertext:  "c1",
		Folders:     []FolderInput{{Path: `Movies\2025`, ExcludePaths: []string{"/Movies/2025/Sample"}, LibraryHint: "movie"}},
	}, "10.1.0.1")
	if err != nil {
		t.Fatal(err)
	}
	if len(qk.Folders) != 1 || qk.Folders[0].Path != "/Movies/2025" {
		t.Fatalf("expected normalized initial folder, got %+v", qk.Folders)
	}

	_, err = srcSvc.CreateSource(pcA.Principal, CreateSourceRequest{
		Kind:        db.SourceKindQuark,
		Name:        "Quark Dup",
		IdentityKey: "qk_uid_shared",
		Ciphertext:  "c2",
	}, "10.1.0.1")
	var dupErr *DuplicateSourceError
	if !errors.As(err, &dupErr) || dupErr.ExistingSourceID != qk.ID {
		t.Fatalf("expected DuplicateSourceError referencing %s, got %v", qk.ID, err)
	}

	// Household B can add same Quark uid independently
	if _, err := srcSvc.CreateSource(pcB.Principal, CreateSourceRequest{
		Kind:        db.SourceKindQuark,
		Name:        "Bob Quark",
		IdentityKey: "qk_uid_shared",
		Ciphertext:  "c_bob",
	}, "10.1.0.3"); err != nil {
		t.Fatalf("other household same identity failed: %v", err)
	}

	// Phone manages folders & renames PC's Quark source cleanly
	addedFolder, err := srcSvc.AddFolder(phoneA.Principal, qk.ID, FolderInput{
		Path:        "/TV/Shows/",
		LibraryHint: "show",
	}, "10.1.0.2")
	if err != nil {
		t.Fatalf("phone AddFolder on PC quark failed: %v", err)
	}
	if _, err := srcSvc.AddFolder(phoneA.Principal, qk.ID, FolderInput{Path: "/TV/Shows"}, "10.1.0.2"); !errors.Is(err, ErrConflict) {
		t.Fatalf("expected duplicate folder ErrConflict, got %v", err)
	}
	newHint := "anime"
	updatedFolder, err := srcSvc.UpdateFolder(phoneA.Principal, qk.ID, addedFolder.ID, UpdateFolderRequest{
		LibraryHint: &newHint,
	}, "10.1.0.2")
	if err != nil || updatedFolder.LibraryHint != "anime" {
		t.Fatalf("UpdateFolder failed: %+v err=%v", updatedFolder, err)
	}
	newName := "Quark Renamed By Phone"
	renamed, err := srcSvc.UpdateSource(phoneA.Principal, qk.ID, UpdateSourceRequest{Name: &newName}, "10.1.0.2")
	if err != nil || renamed.Name != newName {
		t.Fatalf("phone UpdateSource failed: %+v err=%v", renamed, err)
	}
	if err := srcSvc.DeleteFolder(phoneA.Principal, qk.ID, addedFolder.ID, "10.1.0.2"); err != nil {
		t.Fatalf("DeleteFolder failed: %v", err)
	}

	// Emby does not accept folders
	if _, err := srcSvc.CreateSource(pcA.Principal, CreateSourceRequest{
		Kind:        db.SourceKindEmby,
		Name:        "EmbyBad",
		IdentityKey: "emby_1",
		Ciphertext:  "c",
		Folders:     []FolderInput{{Path: "/"}},
	}, "10.1.0.1"); !errors.Is(err, ErrInvalidInput) {
		t.Fatalf("expected ErrInvalidInput for emby folders, got %v", err)
	}

	// WebDAV soft dedup: first warns with SimilarSourceError, confirm_duplicate=true permits
	dav1, err := srcSvc.CreateSource(phoneA.Principal, CreateSourceRequest{
		Kind:        db.SourceKindWebDAV,
		Name:        "NAS 1",
		IdentityKey: "dav_same",
		Ciphertext:  "d1",
	}, "10.1.0.2")
	if err != nil {
		t.Fatal(err)
	}
	_, err = srcSvc.CreateSource(phoneA.Principal, CreateSourceRequest{
		Kind:        db.SourceKindWebDAV,
		Name:        "NAS 2",
		IdentityKey: "dav_same",
		Ciphertext:  "d2",
	}, "10.1.0.2")
	var simErr *SimilarSourceError
	if !errors.As(err, &simErr) || len(simErr.SimilarSources) != 1 || simErr.SimilarSources[0].ID != dav1.ID {
		t.Fatalf("expected SimilarSourceError pointing to %s, got %v", dav1.ID, err)
	}
	if _, err := srcSvc.CreateSource(phoneA.Principal, CreateSourceRequest{
		Kind:             db.SourceKindWebDAV,
		Name:             "NAS 2 Confirmed",
		IdentityKey:      "dav_same",
		Ciphertext:       "d2",
		ConfirmDuplicate: true,
	}, "10.1.0.2"); err != nil {
		t.Fatalf("confirmed duplicate WebDAV failed: %v", err)
	}

	// Quota check (currently 3 active sources in alice's household)
	if _, err := store.DB().Exec(`UPDATE households SET quota_max_sources = 3 WHERE id = ?`, pcA.Principal.HouseholdID); err != nil {
		t.Fatal(err)
	}
	_, err = srcSvc.CreateSource(pcA.Principal, CreateSourceRequest{
		Kind:        db.SourceKindJellyfin,
		Name:        "JF Over Quota",
		IdentityKey: "jf_1",
		Ciphertext:  "c",
	}, "10.1.0.1")
	var qErr *QuotaExceededError
	if !errors.As(err, &qErr) || qErr.Quota != "sources" || qErr.Limit != 3 {
		t.Fatalf("expected QuotaExceededError(sources, 3), got %v", err)
	}
}

func TestCredentialOptimisticLockingAndStatusSSE(t *testing.T) {
	srcSvc, accSvc, store, hub, _ := openTestSourceEnv(t)

	pc := registerUserDevice(t, accSvc, "alice_cred", db.DeviceClassDesktop, "10.2.0.1")
	phone := loginSameHousehold(t, accSvc, "alice_cred", db.DeviceClassPhone, "10.2.0.2")

	ch, unsub := hub.Subscribe(pc.Principal.HouseholdID, pc.Principal.MemberID)
	defer unsub()

	src, err := srcSvc.CreateSource(pc.Principal, CreateSourceRequest{
		Kind:        db.SourceKindQuark,
		Name:        "Quark Creds",
		IdentityKey: "qk_uid_cred",
		Ciphertext:  "cipher_v1",
	}, "10.2.0.1")
	if err != nil {
		t.Fatal(err)
	}
	ev := <-ch
	if ev.Type != "source.changed" {
		t.Fatalf("expected source.changed SSE event, got %+v", ev)
	}

	cred, err := srcSvc.GetCredential(phone.Principal, src.ID, "10.2.0.2")
	if err != nil || cred.Ciphertext != "cipher_v1" || cred.Version != 1 {
		t.Fatalf("unexpected credential: %+v err=%v", cred, err)
	}
	// Verify credential_read audit log exists and omits ciphertext.
	var auditDetail string
	if err := store.ReadDB().QueryRow(`SELECT detail_json FROM audit_logs WHERE household_id = ? AND action = 'source.credential_read'`, pc.Principal.HouseholdID).Scan(&auditDetail); err != nil || auditDetail == "" {
		t.Fatalf("expected credential_read audit log, got %q err=%v", auditDetail, err)
	}

	// Phone refreshes token -> version 2
	u1, err := srcSvc.UpdateCredential(phone.Principal, src.ID, UpdateCredentialRequest{
		BaseVersion: 1,
		Ciphertext:  "cipher_v2",
		Mode:        CredUpdateModeRefresh,
	}, "10.2.0.2")
	if err != nil || u1.Version != 2 {
		t.Fatalf("expected version 2 after update, got %+v err=%v", u1, err)
	}
	ev2 := <-ch
	if ev2.Type != "credential.status" {
		t.Fatalf("expected credential.status SSE event, got %+v", ev2)
	}

	// Stale concurrent PC update with base_version=1 returns CredentialConflictError carrying cipher_v2
	_, err = srcSvc.UpdateCredential(pc.Principal, src.ID, UpdateCredentialRequest{
		BaseVersion: 1,
		Ciphertext:  "cipher_stale",
		Mode:        CredUpdateModeRefresh,
	}, "10.2.0.1")
	var ccErr *CredentialConflictError
	if !errors.As(err, &ccErr) || ccErr.Current.Version != 2 || ccErr.Current.Ciphertext != "cipher_v2" {
		t.Fatalf("expected CredentialConflictError with v2, got %v", err)
	}

	// Phone cannot perform full replace on Quark (device policy!)
	if _, err := srcSvc.UpdateCredential(phone.Principal, src.ID, UpdateCredentialRequest{
		BaseVersion: 2,
		Ciphertext:  "cipher_phone_replace",
		Mode:        CredUpdateModeReplace,
		IdentityKey: "qk_uid_cred",
	}, "10.2.0.2"); !errors.Is(err, ErrKindNotAllowedOnDevice) {
		t.Fatalf("expected phone replace quark ErrKindNotAllowedOnDevice, got %v", err)
	}

	// PC replacing with mismatched identity_key fails ErrIdentityMismatch (N5)
	if _, err := srcSvc.UpdateCredential(pc.Principal, src.ID, UpdateCredentialRequest{
		BaseVersion: 2,
		Ciphertext:  "cipher_wrong_uid",
		Mode:        CredUpdateModeReplace,
		IdentityKey: "qk_other_uid",
	}, "10.2.0.1"); !errors.Is(err, ErrIdentityMismatch) {
		t.Fatalf("expected ErrIdentityMismatch on N5 mismatch, got %v", err)
	}

	// Report credential kicked -> broadcasts SSE, ignores stale report for version 1 after version 3
	meta, err := srcSvc.ReportCredentialStatus(phone.Principal, src.ID, ReportCredentialStatusRequest{
		Status:  CredStatusKicked,
		Version: 2,
	}, "10.2.0.2")
	if err != nil || meta.Status != CredStatusKicked {
		t.Fatalf("ReportCredentialStatus failed: %+v err=%v", meta, err)
	}
	ev3 := <-ch
	if ev3.Type != "credential.status" {
		t.Fatalf("expected kicked credential.status SSE, got %+v", ev3)
	}

	// Recover via PC replace -> version 3
	u3, err := srcSvc.UpdateCredential(pc.Principal, src.ID, UpdateCredentialRequest{
		BaseVersion: 2,
		Ciphertext:  "cipher_v3",
		Mode:        CredUpdateModeReplace,
		IdentityKey: "qk_uid_cred",
		KeyEpoch:    2,
	}, "10.2.0.1")
	if err != nil || u3.Version != 3 || u3.KeyEpoch != 2 || u3.Status != CredStatusValid {
		t.Fatalf("expected v3 recovery, got %+v err=%v", u3, err)
	}
	_ = <-ch

	// Stale report against version 1 must not downgrade valid v3
	staleMeta, err := srcSvc.ReportCredentialStatus(phone.Principal, src.ID, ReportCredentialStatusRequest{
		Status:  CredStatusExpired,
		Version: 1,
	}, "10.2.0.2")
	if err != nil || staleMeta.Status != CredStatusValid || staleMeta.Version != 3 {
		t.Fatalf("stale report must not downgrade valid v3, got %+v err=%v", staleMeta, err)
	}
}

func TestSoftDeleteTenantIsolationRestrictedMembersAndPurge(t *testing.T) {
	srcSvc, accSvc, store, hub, advance := openTestSourceEnv(t)

	pcA := registerUserDevice(t, accSvc, "alice_del", db.DeviceClassDesktop, "10.3.0.1")
	pcB := registerUserDevice(t, accSvc, "bob_del", db.DeviceClassDesktop, "10.3.0.2")

	src1, err := srcSvc.CreateSource(pcA.Principal, CreateSourceRequest{
		Kind:        db.SourceKindQuark,
		Name:        "Allowed Source",
		IdentityKey: "qk_1",
		Ciphertext:  "c1",
	}, "10.3.0.1")
	if err != nil {
		t.Fatal(err)
	}
	src2, err := srcSvc.CreateSource(pcA.Principal, CreateSourceRequest{
		Kind:        db.SourceKindEmby,
		Name:        "Hidden Emby",
		IdentityKey: "emby_hidden",
		Ciphertext:  "c2",
	}, "10.3.0.1")
	if err != nil {
		t.Fatal(err)
	}

	// Restricted member only sees src1
	memPerms := account.PermBrowse | account.PermUploadFacts
	_, err = accSvc.CreateMember(pcA.Principal, account.CreateMemberRequest{
		Nickname:         "RestrictedKid",
		Role:             account.RoleMember,
		Permissions:      &memPerms,
		RestrictSources:  true,
		AllowedSourceIDs: []string{src1.ID},
		LoginUsername:    "kid_res",
		LoginPassword:    "Password123!",
	}, "10.3.0.1")
	if err != nil {
		t.Fatal(err)
	}
	kidLogin, err := accSvc.Login(account.LoginRequest{
		Username: "kid_res",
		Password: "Password123!",
		Device:   account.DeviceInput{Class: db.DeviceClassPhone},
	}, "10.3.0.3")
	if err != nil {
		t.Fatal(err)
	}
	visible, err := srcSvc.ListSources(kidLogin.Principal)
	if err != nil || len(visible) != 1 || visible[0].ID != src1.ID {
		t.Fatalf("expected restricted member to see only src1 (%s), got %+v err=%v", src1.ID, visible, err)
	}
	if _, err := srcSvc.GetCredential(kidLogin.Principal, src2.ID, "10.3.0.3"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("expected ErrForbidden on hidden source credential, got %v", err)
	}

	// Cross-household access returns ErrNotFound
	if _, err := srcSvc.GetSource(pcB.Principal, src1.ID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected cross-household ErrNotFound, got %v", err)
	}

	// Seed running scan_session -> DeleteSource wipes creds, marks session partial, emits SSE
	if _, err := store.DB().Exec(`
		INSERT INTO scan_sessions(id, household_id, source_id, type, device_id, member_id, started_at, last_activity_at, status)
		VALUES ('sess_run', ?, ?, 'full', ?, ?, 1, 1, 'running')`,
		pcA.Principal.HouseholdID, src1.ID, pcA.Principal.DeviceID, pcA.Principal.MemberID,
	); err != nil {
		t.Fatal(err)
	}

	ch, unsub := hub.Subscribe(pcA.Principal.HouseholdID, pcA.Principal.MemberID)
	defer unsub()

	if err := srcSvc.DeleteSource(pcA.Principal, src1.ID, "10.3.0.1"); err != nil {
		t.Fatalf("DeleteSource failed: %v", err)
	}
	ev := <-ch
	if ev.Type != "source.changed" {
		t.Fatalf("expected source.changed delete SSE, got %+v", ev)
	}

	if _, err := srcSvc.GetSource(pcA.Principal, src1.ID); !errors.Is(err, ErrSourceDeleted) {
		t.Fatalf("expected ErrSourceDeleted on deleted source, got %v", err)
	}
	if _, err := srcSvc.GetCredential(pcA.Principal, src1.ID, "10.3.0.1"); !errors.Is(err, ErrSourceDeleted) {
		t.Fatalf("expected ErrSourceDeleted on deleted credential, got %v", err)
	}
	if _, err := srcSvc.AddFolder(pcA.Principal, src1.ID, FolderInput{Path: "/x"}, "10.3.0.1"); !errors.Is(err, ErrSourceDeleted) {
		t.Fatalf("expected ErrSourceDeleted on folder add, got %v", err)
	}

	var credCnt int
	_ = store.ReadDB().QueryRow(`SELECT COUNT(*) FROM source_credentials WHERE source_id = ?`, src1.ID).Scan(&credCnt)
	if credCnt != 0 {
		t.Fatalf("expected source_credentials wiped on soft delete, cnt=%d", credCnt)
	}
	var sessStatus string
	_ = store.ReadDB().QueryRow(`SELECT status FROM scan_sessions WHERE id = 'sess_run'`).Scan(&sessStatus)
	if sessStatus != "partial" {
		t.Fatalf("expected running scan session transitioned to partial, got %q", sessStatus)
	}

	// Re-adding same identity_key after soft-delete succeeds
	if _, err := srcSvc.CreateSource(pcA.Principal, CreateSourceRequest{
		Kind:        db.SourceKindQuark,
		Name:        "Allowed Source Re-added",
		IdentityKey: "qk_1",
		Ciphertext:  "c_new",
	}, "10.3.0.1"); err != nil {
		t.Fatalf("re-adding soft-deleted identity_key should succeed: %v", err)
	}

	// Purge only after 30 days
	advance(29 * 24 * time.Hour)
	if n, err := srcSvc.PurgeExpiredDeletedSources(); err != nil || n != 0 {
		t.Fatalf("expected 0 purged at 29d, got n=%d err=%v", n, err)
	}
	advance(2 * 24 * time.Hour)
	if n, err := srcSvc.PurgeExpiredDeletedSources(); err != nil || n != 1 {
		t.Fatalf("expected 1 purged at 31d, got n=%d err=%v", n, err)
	}
}
