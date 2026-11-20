package account

import (
	"errors"
	"testing"
	"time"

	"plezy/media_library/internal/db"
	"plezy/media_library/internal/keyring"
	"plezy/media_library/internal/security"
	"plezy/media_library/internal/vault"
)

func openTestAccountSvc(t *testing.T) (*Service, *db.Store, func(time.Duration)) {
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

	svc := NewService(store, security.NewLoginLimiter())
	now := time.Unix(1700000000, 0)
	svc.SetClock(func() time.Time { return now })
	return svc, store, func(d time.Duration) { now = now.Add(d) }
}

func makeWrapInput(wrapType, wrapped string) KeyWrapInput {
	return KeyWrapInput{
		WrapType:      wrapType,
		KdfAlg:        keyring.KdfAlgPBKDF2,
		KdfSalt:       "c2FsdF8xMjM0",
		KdfParamsJSON: `{"iterations":600000}`,
		WrappedHK:     wrapped,
		KeyEpoch:      1,
	}
}

func TestRegistrationModesAndRateLimit(t *testing.T) {
	svc, store, advance := openTestAccountSvc(t)

	// 1. Closed registration
	closed := db.RegistrationModeClosed
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{RegistrationMode: &closed}); err != nil {
		t.Fatal(err)
	}
	_, err := svc.Register(RegisterRequest{
		Username: "alice",
		Password: "Password123!",
		Device:   DeviceInput{Class: db.DeviceClassDesktop, Platform: "windows", Name: "PC"},
	}, "10.0.0.1")
	if !errors.Is(err, ErrRegistrationClosed) {
		t.Fatalf("expected ErrRegistrationClosed, got %v", err)
	}

	// 2. Invite-only registration
	invite := db.RegistrationModeInvite
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{RegistrationMode: &invite}); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Register(RegisterRequest{
		Username:   "alice",
		Password:   "Password123!",
		InviteCode: "BADCODE",
		Device:     DeviceInput{Class: db.DeviceClassDesktop},
	}, "10.0.0.2"); !errors.Is(err, ErrInvalidInvite) {
		t.Fatalf("expected ErrInvalidInvite, got %v", err)
	}

	// Seed a single-use invite code.
	if _, err := store.DB().Exec(`
		INSERT INTO invite_codes(code, created_by, max_uses, used_count, revoked, created_at)
		VALUES ('INVITE123', 'admin1', 1, 0, 0, 1700000000000)`,
	); err != nil {
		t.Fatal(err)
	}
	res, err := svc.Register(RegisterRequest{
		Username:   "alice",
		Password:   "Password123!",
		InviteCode: "invite123", // case-insensitive check
		Device:     DeviceInput{Class: db.DeviceClassDesktop, Platform: "windows", Name: "WorkPC"},
	}, "10.0.0.2")
	if err != nil {
		t.Fatalf("invite registration failed: %v", err)
	}
	if res.AccessToken == "" || res.Principal == nil || res.Principal.Role != RoleOwner {
		t.Fatalf("unexpected auth result: %+v", res)
	}

	// Reusing single-use invite fails.
	if _, err := svc.Register(RegisterRequest{
		Username:   "bob",
		Password:   "Password123!",
		InviteCode: "INVITE123",
		Device:     DeviceInput{Class: db.DeviceClassDesktop},
	}, "10.0.0.3"); !errors.Is(err, ErrInvalidInvite) {
		t.Fatalf("expected ErrInvalidInvite on exhausted code, got %v", err)
	}

	// 3. Open registration + per-IP rate limit (5/hour)
	openMode := db.RegistrationModeOpen
	if _, err := store.UpdateServerSettings(db.ServerSettingsUpdate{RegistrationMode: &openMode}); err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 5; i++ {
		u := "user_" + string(rune('a'+i))
		if _, err := svc.Register(RegisterRequest{
			Username: u,
			Password: "Password123!",
			Device:   DeviceInput{Class: db.DeviceClassPhone},
		}, "10.0.0.99"); err != nil {
			t.Fatalf("open registration #%d failed: %v", i, err)
		}
	}
	if _, err := svc.Register(RegisterRequest{
		Username: "user_sixth",
		Password: "Password123!",
		Device:   DeviceInput{Class: db.DeviceClassPhone},
	}, "10.0.0.99"); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("expected ErrRateLimited on 6th registration, got %v", err)
	}
	advance(time.Hour + time.Minute)
	if _, err := svc.Register(RegisterRequest{
		Username: "user_after_window",
		Password: "Password123!",
		Device:   DeviceInput{Class: db.DeviceClassPhone},
	}, "10.0.0.99"); err != nil {
		t.Fatalf("expected registration after rate window to succeed: %v", err)
	}
}

func TestLoginMemberTicketPINAndSwitchMember(t *testing.T) {
	svc, _, advance := openTestAccountSvc(t)

	reg, err := svc.Register(RegisterRequest{
		Username:     "family_owner",
		Email:        "Owner@Example.com",
		Password:     "OwnerPass123!",
		RecoveryCode: "REC-ALPHA-9999",
		Device:       DeviceInput{Class: db.DeviceClassDesktop, Platform: "windows", Name: "MainPC"},
		KeyWraps: []KeyWrapInput{
			makeWrapInput(keyring.WrapAccountPassword, "hk_wrapped_acc"),
			makeWrapInput(keyring.WrapRecoveryCode, "hk_wrapped_rec"),
		},
	}, "10.1.0.1")
	if err != nil {
		t.Fatal(err)
	}

	// Single member without PIN logs in directly.
	direct, err := svc.Login(LoginRequest{
		Username: "owner@example.com",
		Password: "OwnerPass123!",
		Device:   DeviceInput{Class: db.DeviceClassPhone, Platform: "ios", Name: "iPhone"},
	}, "10.1.0.1")
	if err != nil || direct.RequiresMemberSelect || direct.AccessToken == "" {
		t.Fatalf("expected direct login, got res=%+v err=%v", direct, err)
	}

	// Add PIN-protected admin and independent child member with member_password wrap.
	perms := PermBrowse | PermUploadFacts
	childWrap := makeWrapInput(keyring.WrapMemberPassword, "hk_wrapped_child")
	child, err := svc.CreateMember(reg.Principal, CreateMemberRequest{
		Nickname:      "Kiddo",
		Role:          RoleMember,
		Permissions:   &perms,
		PIN:           "2468",
		LoginUsername: "kid_solo",
		LoginPassword: "KidPass123!",
		MemberWrap:    &childWrap,
	}, "10.1.0.1")
	if err != nil {
		t.Fatal(err)
	}

	// Now multi-member login yields a 5-min login ticket instead of immediate session.
	step1, err := svc.Login(LoginRequest{
		Username: "family_owner",
		Password: "OwnerPass123!",
		Device:   DeviceInput{Class: db.DeviceClassTV, Platform: "androidtv", Name: "LivingRoomTV"},
	}, "10.1.0.2")
	if err != nil || !step1.RequiresMemberSelect || step1.LoginTicket == "" || step1.AccessToken != "" {
		t.Fatalf("expected login ticket, got res=%+v err=%v", step1, err)
	}
	if len(step1.Members) != 2 {
		t.Fatalf("expected 2 members, got %d", len(step1.Members))
	}

	// Wrong PIN fails and triggers lockout after 5 failures.
	for i := 0; i < 5; i++ {
		_, err := svc.SelectMember(SelectMemberRequest{
			LoginTicket: step1.LoginTicket,
			MemberID:    child.ID,
			PIN:         "0000",
		}, "10.1.0.2")
		if !errors.Is(err, ErrInvalidCredentials) {
			t.Fatalf("attempt %d: expected ErrInvalidCredentials, got %v", i, err)
		}
	}
	if _, err := svc.SelectMember(SelectMemberRequest{
		LoginTicket: step1.LoginTicket,
		MemberID:    child.ID,
		PIN:         "2468",
	}, "10.1.0.2"); !errors.Is(err, ErrRateLimited) {
		t.Fatalf("expected PIN lockout ErrRateLimited, got %v", err)
	}

	// Advance past lockout (15m) -> old 5-min ticket is now expired.
	advance(16 * time.Minute)
	if _, err := svc.SelectMember(SelectMemberRequest{
		LoginTicket: step1.LoginTicket,
		MemberID:    child.ID,
		PIN:         "2468",
	}, "10.1.0.2"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected expired ticket ErrUnauthorized, got %v", err)
	}

	// Fresh login -> valid SelectMember consumes ticket once.
	step2, err := svc.Login(LoginRequest{
		Username: "family_owner",
		Password: "OwnerPass123!",
		Device:   DeviceInput{Class: db.DeviceClassTV},
	}, "10.1.0.2")
	if err != nil {
		t.Fatal(err)
	}
	selected, err := svc.SelectMember(SelectMemberRequest{
		LoginTicket: step2.LoginTicket,
		MemberID:    child.ID,
		PIN:         "2468",
	}, "10.1.0.2")
	if err != nil || selected.AccessToken == "" || selected.Principal.MemberID != child.ID {
		t.Fatalf("expected session after SelectMember, got res=%+v err=%v", selected, err)
	}
	// Ticket replay must fail.
	if _, err := svc.SelectMember(SelectMemberRequest{
		LoginTicket: step2.LoginTicket,
		MemberID:    reg.Member.ID,
	}, "10.1.0.2"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected ticket replay failure, got %v", err)
	}

	// Household-mode session can switch back to owner (no PIN).
	switched, err := svc.SwitchMember(selected.Principal, reg.Member.ID, "", "10.1.0.2")
	if err != nil || switched.Principal.MemberID != reg.Member.ID {
		t.Fatalf("SwitchMember failed: res=%+v err=%v", switched, err)
	}

	// Independent member login creates member_only session with strictly scoped wraps.
	solo, err := svc.Login(LoginRequest{
		Username: "kid_solo",
		Password: "KidPass123!",
		Device:   DeviceInput{Class: db.DeviceClassPhone, Platform: "android", Name: "KidPhone"},
	}, "10.1.0.3")
	if err != nil || solo.LoginMode != LoginModeMemberOnly {
		t.Fatalf("expected member_only login, got res=%+v err=%v", solo, err)
	}
	if len(solo.KeyWraps) != 1 || solo.KeyWraps[0].WrapType != keyring.WrapMemberPassword || solo.KeyWraps[0].SubjectID != child.ID {
		t.Fatalf("member_only must only receive own member_password wrap, got %+v", solo.KeyWraps)
	}
	if _, err := svc.SwitchMember(solo.Principal, reg.Member.ID, "", "10.1.0.3"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("expected SwitchMember forbidden for member_only, got %v", err)
	}
	if _, err := svc.Authenticate("adm_notausertoken"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected adm_ prefix rejected by account.Authenticate, got %v", err)
	}
}

func TestTenantIsolationAndOwnerProtection(t *testing.T) {
	svc, _, _ := openTestAccountSvc(t)

	alice, err := svc.Register(RegisterRequest{
		Username: "alice",
		Password: "Password123!",
		Device:   DeviceInput{Class: db.DeviceClassDesktop},
	}, "10.2.0.1")
	if err != nil {
		t.Fatal(err)
	}
	bob, err := svc.Register(RegisterRequest{
		Username: "bob_user",
		Password: "Password123!",
		Device:   DeviceInput{Class: db.DeviceClassDesktop},
	}, "10.2.0.2")
	if err != nil {
		t.Fatal(err)
	}

	// Add an admin member in Alice's household.
	newNick := "HelperAdmin"
	aliceAdmin, err := svc.CreateMember(alice.Principal, CreateMemberRequest{
		Nickname:      newNick,
		Role:          RoleAdmin,
		LoginUsername: "alice_adm",
		LoginPassword: "Password123!",
	}, "10.2.0.1")
	if err != nil {
		t.Fatal(err)
	}
	aliceAdminRes, err := svc.Login(LoginRequest{
		Username: "alice_adm",
		Password: "Password123!",
		Device:   DeviceInput{Class: db.DeviceClassPhone},
	}, "10.2.0.1")
	if err != nil {
		t.Fatal(err)
	}

	// Cross-household operations return ErrNotFound (404).
	hackNick := "Hacked"
	if _, err := svc.UpdateMember(bob.Principal, alice.Member.ID, UpdateMemberRequest{Nickname: &hackNick}, "10.2.0.2"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected cross-household UpdateMember ErrNotFound, got %v", err)
	}
	if err := svc.DeleteMember(bob.Principal, aliceAdmin.ID, "10.2.0.2"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected cross-household DeleteMember ErrNotFound, got %v", err)
	}
	if err := svc.RevokeDevice(bob.Principal, alice.Principal.DeviceID, "10.2.0.2"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected cross-household RevokeDevice ErrNotFound, got %v", err)
	}
	if err := svc.RevokeSession(bob.Principal, alice.TokenID, "10.2.0.2"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("expected cross-household RevokeSession ErrNotFound, got %v", err)
	}

	// Non-owner admin cannot modify owner.
	if _, err := svc.UpdateMember(aliceAdminRes.Principal, alice.Member.ID, UpdateMemberRequest{Nickname: &hackNick}, "10.2.0.1"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("expected non-owner editing owner ErrForbidden, got %v", err)
	}
	// Owner cannot be demoted even by owner.
	demote := RoleAdmin
	if _, err := svc.UpdateMember(alice.Principal, alice.Member.ID, UpdateMemberRequest{Role: &demote}, "10.2.0.1"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("expected owner demotion ErrForbidden, got %v", err)
	}
}

func TestPasswordChangeRecoveryAndSelfDelete(t *testing.T) {
	svc, store, _ := openTestAccountSvc(t)

	reg1, err := svc.Register(RegisterRequest{
		Username:     "rec_user",
		Password:     "OldPass123!",
		RecoveryCode: "RECOV-CODE-8888",
		Device:       DeviceInput{Class: db.DeviceClassDesktop},
		KeyWraps: []KeyWrapInput{
			makeWrapInput(keyring.WrapAccountPassword, "wrapped_old"),
			makeWrapInput(keyring.WrapRecoveryCode, "wrapped_rec"),
		},
	}, "10.3.0.1")
	if err != nil {
		t.Fatal(err)
	}
	// Second session so we can confirm ChangeAccountPassword revokes other sessions.
	reg2, err := svc.Login(LoginRequest{
		Username: "rec_user",
		Password: "OldPass123!",
		Device:   DeviceInput{Class: db.DeviceClassPhone},
	}, "10.3.0.1")
	if err != nil {
		t.Fatal(err)
	}

	newAccWrap := makeWrapInput(keyring.WrapAccountPassword, "wrapped_changed")
	if err := svc.ChangeAccountPassword(reg1.Principal, ChangePasswordRequest{
		OldPassword:    "OldPass123!",
		NewPassword:    "ChangedPass123!",
		NewAccountWrap: &newAccWrap,
	}, "10.3.0.1"); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Authenticate(reg1.AccessToken); err != nil {
		t.Fatalf("current session should stay valid: %v", err)
	}
	if _, err := svc.Authenticate(reg2.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("other session should be revoked, got %v", err)
	}

	// Recovery wrap lookup verifies recovery code first.
	if _, err := svc.GetRecoveryWrap("rec_user", "WRONG-CODE", "10.3.0.2"); !errors.Is(err, ErrInvalidCredentials) {
		t.Fatalf("expected ErrInvalidCredentials for wrong recovery code, got %v", err)
	}
	recWrap, err := svc.GetRecoveryWrap("rec_user", "RECOV-CODE-8888", "10.3.0.2")
	if err != nil || recWrap.WrappedHK != "wrapped_rec" {
		t.Fatalf("unexpected recovery wrap: %+v err=%v", recWrap, err)
	}

	recoveredWrap := makeWrapInput(keyring.WrapAccountPassword, "wrapped_recovered")
	if err := svc.RecoverAccountPassword(RecoverPasswordRequest{
		Username:       "rec_user",
		RecoveryCode:   "RECOV-CODE-8888",
		NewPassword:    "RecoveredPass123!",
		NewAccountWrap: &recoveredWrap,
	}, "10.3.0.2"); err != nil {
		t.Fatal(err)
	}
	if _, err := svc.Authenticate(reg1.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("all sessions must be revoked on recovery, got %v", err)
	}
	loggedIn, err := svc.Login(LoginRequest{
		Username: "rec_user",
		Password: "RecoveredPass123!",
		Device:   DeviceInput{Class: db.DeviceClassDesktop},
	}, "10.3.0.2")
	if err != nil {
		t.Fatal(err)
	}
	wraps, err := svc.ListMyKeyWraps(loggedIn.Principal)
	if err != nil {
		t.Fatal(err)
	}
	foundUpdated := false
	for _, w := range wraps {
		if w.WrapType == keyring.WrapAccountPassword && w.WrappedHK == "wrapped_recovered" {
			foundUpdated = true
		}
	}
	if !foundUpdated {
		t.Fatalf("expected updated account wrap after recovery, got %+v", wraps)
	}

	// Seed a source + encrypted credential to confirm 7-day self-delete wipes source_credentials.
	if _, err := store.DB().Exec(`
		INSERT INTO sources(id, household_id, kind, name, identity_key, created_by_member, created_by_device, created_at, updated_at)
		VALUES ('src1', ?, 'webdav', 'NAS', 'idk1', ?, ?, 1, 1);
		INSERT INTO source_credentials(source_id, household_id, ciphertext, updated_by_device, updated_at)
		VALUES ('src1', ?, 'cipher_creds', ?, 1);`,
		loggedIn.Principal.HouseholdID, loggedIn.Principal.MemberID, loggedIn.Principal.DeviceID, loggedIn.Principal.HouseholdID, loggedIn.Principal.DeviceID,
	); err != nil {
		t.Fatal(err)
	}

	delAfter, err := svc.ScheduleSelfDelete(loggedIn.Principal, "RecoveredPass123!", "10.3.0.2")
	if err != nil || delAfter <= time.Unix(1700000000, 0).UnixMilli() {
		t.Fatalf("unexpected ScheduleSelfDelete result: delAfter=%d err=%v", delAfter, err)
	}
	if _, err := svc.Authenticate(loggedIn.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected deleted session unauthorized, got %v", err)
	}
	var credCnt int
	if err := store.ReadDB().QueryRow(`SELECT COUNT(*) FROM source_credentials WHERE household_id = ?`, loggedIn.Principal.HouseholdID).Scan(&credCnt); err != nil || credCnt != 0 {
		t.Fatalf("expected source_credentials wiped on delete, cnt=%d err=%v", credCnt, err)
	}
	if _, err := svc.Login(LoginRequest{
		Username: "rec_user",
		Password: "RecoveredPass123!",
		Device:   DeviceInput{Class: db.DeviceClassDesktop},
	}, "10.3.0.2"); !errors.Is(err, ErrAccountPendingDelete) {
		t.Fatalf("expected ErrAccountPendingDelete on login, got %v", err)
	}
}

func TestQrLoginE2EEHandshakeAndDeviceSessionRevoke(t *testing.T) {
	svc, _, _ := openTestAccountSvc(t)

	phone, err := svc.Register(RegisterRequest{
		Username: "qr_owner",
		Password: "Password123!",
		Device:   DeviceInput{Class: db.DeviceClassPhone, Platform: "ios", Name: "Phone"},
	}, "10.4.0.1")
	if err != nil {
		t.Fatal(err)
	}
	regularMember, err := svc.CreateMember(phone.Principal, CreateMemberRequest{
		Nickname:      "PlainMember",
		Role:          RoleMember,
		LoginUsername: "plain_mem",
		LoginPassword: "Password123!",
	}, "10.4.0.1")
	if err != nil {
		t.Fatal(err)
	}
	plainSession, err := svc.Login(LoginRequest{
		Username: "qr_owner",
		Password: "Password123!",
		MemberID: regularMember.ID,
		Device:   DeviceInput{Class: db.DeviceClassDesktop},
	}, "10.4.0.1")
	if err != nil {
		t.Fatal(err)
	}

	qr, err := svc.CreateQrSession(CreateQrRequest{
		DeviceClass:     db.DeviceClassTV,
		Platform:        "androidtv",
		DeviceName:      "Sony TV",
		EphemeralPubkey: "x25519_pub_base64",
	}, "10.4.0.2")
	if err != nil {
		t.Fatal(err)
	}

	if _, err := svc.PollQrSession(qr.QrID, "qrs_wrong_secret", "10.4.0.2"); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected wrong poll_secret ErrUnauthorized, got %v", err)
	}
	pending, err := svc.PollQrSession(qr.QrID, qr.PollSecret, "10.4.0.2")
	if err != nil || pending.Status != "pending" {
		t.Fatalf("expected pending poll, got %+v err=%v", pending, err)
	}

	info, err := svc.GetQrSessionInfo(qr.QrID)
	if err != nil || info.EphemeralPubkey != "x25519_pub_base64" {
		t.Fatalf("unexpected GetQrSessionInfo: %+v err=%v", info, err)
	}

	// Plain member without PermManageMembers cannot confirm QR on behalf of owner.
	if err := svc.ConfirmQrSession(plainSession.Principal, qr.QrID, ConfirmQrRequest{
		TargetMemberID: phone.Member.ID,
		EncryptedHK:    "cipher_hk_for_tv",
	}, "10.4.0.1"); !errors.Is(err, ErrForbidden) {
		t.Fatalf("expected ConfirmQrSession ErrForbidden for plain member targeting owner, got %v", err)
	}

	if err := svc.ConfirmQrSession(phone.Principal, qr.QrID, ConfirmQrRequest{
		EncryptedHK: "cipher_hk_for_tv",
	}, "10.4.0.1"); err != nil {
		t.Fatalf("ConfirmQrSession failed: %v", err)
	}
	if err := svc.ConfirmQrSession(phone.Principal, qr.QrID, ConfirmQrRequest{
		EncryptedHK: "cipher_hk_for_tv",
	}, "10.4.0.1"); !errors.Is(err, ErrConflict) {
		t.Fatalf("expected second ConfirmQrSession ErrConflict, got %v", err)
	}

	polled, err := svc.PollQrSession(qr.QrID, qr.PollSecret, "10.4.0.2")
	if err != nil || polled.Status != "confirmed" || polled.AccessToken == "" || polled.EncryptedHK != "cipher_hk_for_tv" {
		t.Fatalf("unexpected confirmed poll: %+v err=%v", polled, err)
	}
	// Single-consume invariant: second poll must fail.
	if _, err := svc.PollQrSession(qr.QrID, qr.PollSecret, "10.4.0.2"); !errors.Is(err, ErrConflict) {
		t.Fatalf("expected replay poll ErrConflict, got %v", err)
	}

	tvPrincipal, err := svc.Authenticate(polled.AccessToken)
	if err != nil || tvPrincipal.DeviceClass != db.DeviceClassTV {
		t.Fatalf("expected valid TV principal, got %+v err=%v", tvPrincipal, err)
	}

	devices, err := svc.ListDevices(phone.Principal)
	if err != nil || len(devices) < 3 {
		t.Fatalf("expected >=3 devices, got %d err=%v", len(devices), err)
	}
	sessions, err := svc.ListSessions(phone.Principal)
	if err != nil || len(sessions) < 3 {
		t.Fatalf("expected >=3 sessions, got %d err=%v", len(sessions), err)
	}

	if err := svc.RevokeDevice(phone.Principal, tvPrincipal.DeviceID, "10.4.0.1"); err != nil {
		t.Fatalf("RevokeDevice failed: %v", err)
	}
	if _, err := svc.Authenticate(polled.AccessToken); !errors.Is(err, ErrUnauthorized) {
		t.Fatalf("expected revoked TV token unauthorized, got %v", err)
	}
}
