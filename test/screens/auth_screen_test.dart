import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_local_store.dart';
import 'package:plezy/screens/auth_screen.dart';
import 'package:plezy/screens/storage/sync_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
  });

  testWidgets('AuthScreen offers Local/LAN and Cloud Sync modes without Plex', (tester) async {
    await tester.pumpWidget(
      TranslationProvider(child: const MaterialApp(home: AuthScreen(initializeServices: false))),
    );
    await tester.pump();

    expect(find.text(t.sync.modeLanTitle), findsOneWidget);
    expect(find.text(t.sync.modeCloudTitle), findsOneWidget);
    expect(find.text(t.auth.connectToMediaBrowser(product: 'Jellyfin')), findsOneWidget);
    expect(find.text(t.auth.connectToMediaBrowser(product: 'Emby')), findsOneWidget);
    expect(find.text(t.auth.signInWithPlex), findsNothing);
  });

  testWidgets('tapping Cloud Sync mode opens SyncSettingsScreen in onboarding mode', (tester) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final manager = MountManager(MountRegistry(db));
    final sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: manager,
      enableLanUdp: false,
      autoStartLanService: false,
    );
    addTearDown(() async {
      sync.dispose();
      await manager.dispose();
      await db.close();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncAndScanCoordinator>.value(
        value: sync,
        child: TranslationProvider(child: const MaterialApp(home: AuthScreen(initializeServices: false))),
      ),
    );
    await tester.pump();

    await tester.tap(find.text(t.sync.modeCloudTitle));
    await tester.pumpAndSettle();

    expect(find.byType(SyncSettingsScreen), findsOneWidget);
    expect(find.text(t.sync.register), findsOneWidget);
  });

  test('selecting Local/LAN mode completes onboarding without requiring a server', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final manager = MountManager(MountRegistry(db));
    final sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: manager,
      enableLanUdp: false,
      autoStartLanService: false,
    );
    addTearDown(() async {
      sync.dispose();
      await manager.dispose();
      await db.close();
    });

    await sync.initialize();
    expect(await sync.syncStore.isOnboardingCompleted(), isFalse);

    await sync.selectLanMode(startService: false);
    expect(sync.syncMode, SyncMode.lanP2p);
    expect(await sync.syncStore.isOnboardingCompleted(), isTrue);
  });
}
