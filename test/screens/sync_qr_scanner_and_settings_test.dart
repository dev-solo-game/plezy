import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/sync/sync_api_client.dart';
import 'package:plezy/library/sync/sync_coordinator.dart';
import 'package:plezy/library/sync/sync_crypto.dart';
import 'package:plezy/screens/storage/sync_qr_scanner_screen.dart';
import 'package:plezy/screens/storage/sync_settings_screen.dart';
import 'package:plezy/services/credential_vault.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:plezy/utils/device_identity.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';
import '../test_helpers/pump.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
    DeviceIdentityService.debugOverride(const DeviceIdentity(platform: 'Windows', deviceName: 'Test PC'));
    addTearDown(() => DeviceIdentityService.debugOverride(null));
  });

  void useLargeSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  Future<({AppDatabase db, MountManager manager, SyncAndScanCoordinator sync})> createSync({
    SyncApiClient? apiClient,
  }) async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final repo = LibraryRepository(db);
    final manager = MountManager(MountRegistry(db));
    final sync = SyncAndScanCoordinator(
      db: db,
      repo: repo,
      mountManager: manager,
      apiClient: apiClient,
      enableLanUdp: false,
      autoStartLanService: false,
    );
    await sync.initialize();
    return (db: db, manager: manager, sync: sync);
  }

  testWidgets('SyncQrScannerScreen requires login when signed out', (tester) async {
    final h = await createSync();
    addTearDown(() async {
      h.sync.dispose();
      await h.manager.dispose();
      await h.db.close();
    });

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncAndScanCoordinator>.value(
        value: h.sync,
        child: TranslationProvider(
          child: const MaterialApp(home: SyncQrScannerScreen(cameraPreviewOverride: SizedBox.expand())),
        ),
      ),
    );
    await tester.pump();

    expect(find.text(t.sync.scanQrRequireLoginTitle), findsOneWidget);
    expect(find.text(t.sync.goToSyncLogin), findsOneWidget);
  });

  testWidgets('SyncQrScannerScreen displays account banner and maps server mismatch on paste', (tester) async {
    final h = await createSync();
    addTearDown(() async {
      h.sync.dispose();
      await h.manager.dispose();
      await h.db.close();
    });

    h.sync.debugSetSessionForTesting(
      SyncSessionCredentials(
        serverUrl: 'https://nas.example.com:8088',
        userId: 'u-self',
        username: 'nas_admin',
        accessToken: 'tok-self',
        masterKey: Uint8List.fromList(List<int>.filled(32, 3)),
        serverKind: SyncServerKind.selfHosted,
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncAndScanCoordinator>.value(
        value: h.sync,
        child: TranslationProvider(
          child: const MaterialApp(
            home: SyncQrScannerScreen(cameraPreviewOverride: SizedBox.expand(child: Text('camera-mock'))),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(find.text('camera-mock'), findsOneWidget);
    expect(find.text(t.sync.qrScannerAccountBanner(mode: t.sync.selfHostedBadge, name: 'nas_admin')), findsOneWidget);
    expect(find.text('https://nas.example.com:8088'), findsOneWidget);

    await tester.tap(find.text(t.sync.qrPasteManualButton));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'ttplay://qr-auth?mode=server&server=http://127.0.0.1:8088&session_id=s1&pub_key=k1',
    );
    await tester.tap(find.text(t.sync.qrAuthorizeButton));
    await tester.pumpAndSettle();

    expect(
      find.text(t.sync.qrErrServerMismatch(target: 'http://127.0.0.1:8088', current: 'https://nas.example.com:8088')),
      findsOneWidget,
    );
    expect(find.text(t.sync.qrRescanButton), findsOneWidget);
  });

  testWidgets('SyncSettingsScreen hides Server URL in Official mode and shows QR card on PC/TV', (tester) async {
    final h = await createSync();
    addTearDown(() async {
      h.sync.dispose();
      await h.manager.dispose();
      await h.db.close();
    });

    await h.sync.syncStore.saveLastSelfHostedUrl('https://my-nas.local:8088');

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncAndScanCoordinator>.value(
        value: h.sync,
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: const SyncSettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Official is selected by default: Server URL hidden, QR card shown on non-mobile.
    expect(find.text(t.sync.serverUrl), findsNothing);
    final outerScrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.text(t.sync.qrLoginTitle), 200, scrollable: outerScrollable);
    expect(find.text(t.sync.qrLoginTitle), findsOneWidget);

    // Switching to Self-Hosted shows saved Server URL and standard Server QR card (no LAN ChoiceChips).
    await tester.scrollUntilVisible(find.text(t.sync.modeSelfHostedTitle), -200, scrollable: outerScrollable);
    await tester.tap(find.text(t.sync.modeSelfHostedTitle));
    await tester.pumpAndSettle();

    expect(find.text(t.sync.serverUrl), findsOneWidget);
    expect(find.text('https://my-nas.local:8088'), findsOneWidget);
    expect(find.text(t.sync.testConnection), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    await tester.scrollUntilVisible(find.text(t.sync.qrGenerate), 200, scrollable: outerScrollable);
    expect(find.text(t.sync.qrLoginTitle), findsOneWidget);
    expect(find.text(t.sync.qrModeServerHint), findsOneWidget);
    expect(find.text(t.sync.qrGenerate), findsOneWidget);
  });

  testWidgets('SyncQrScannerScreen authorizes valid QR via confirmQrSession and pops true', (tester) async {
    String? confirmedSessionId;
    String? capturedSealedKey;
    final mockClient = MockClient((req) async {
      expect(req.method, 'POST');
      expect(req.url.path, '/api/v1/auth/qr/confirm');
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      confirmedSessionId = body['session_id'] as String?;
      capturedSealedKey = body['sealed_master_key'] as String?;
      return http.Response(jsonEncode({'code': 0}), 200, headers: {'content-type': 'application/json'});
    });
    final apiClient = SyncApiClient(httpClient: mockClient);
    addTearDown(apiClient.close);

    const serverUrl = 'https://sync.official.test';
    final h = await createSync(apiClient: apiClient);
    addTearDown(() async {
      h.sync.dispose();
      await h.manager.dispose();
      await h.db.close();
    });

    h.sync.debugSetSessionForTesting(
      SyncSessionCredentials(
        serverUrl: serverUrl,
        userId: 'u-off',
        username: 'official_u',
        accessToken: 'tok-off',
        masterKey: Uint8List.fromList(List<int>.filled(32, 9)),
        serverKind: SyncServerKind.official,
      ),
    );
    final tvKp = await SyncQrKeyPairFuture.generate();
    final qrUri = Uri(
      scheme: 'ttplay',
      host: 'qr-auth',
      queryParameters: {
        'mode': 'server',
        'kind': 'official',
        'server': serverUrl,
        'session_id': 'sess-ok-1',
        'pub_key': tvKp.publicKeyBase64,
      },
    ).toString();

    bool? poppedResult;
    await tester.pumpWidget(
      ChangeNotifierProvider<SyncAndScanCoordinator>.value(
        value: h.sync,
        child: TranslationProvider(
          child: MaterialApp(
            home: Builder(
              builder: (ctx) => Scaffold(
                body: ElevatedButton(
                  onPressed: () async {
                    poppedResult = await Navigator.of(ctx).push<bool>(
                      MaterialPageRoute<bool>(
                        builder: (_) => const SyncQrScannerScreen(cameraPreviewOverride: SizedBox.expand()),
                      ),
                    );
                  },
                  child: const Text('open-scanner'),
                ),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('open-scanner'));
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.sync.qrPasteManualButton));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), qrUri);
    await tester.tap(find.text(t.sync.qrAuthorizeButton));
    await tester.pumpAndSettle();

    expect(confirmedSessionId, 'sess-ok-1');
    expect(capturedSealedKey, isNotNull);
    expect(
      await SyncCrypto.unsealMasterKeyOnTv(sealedEnvelope: capturedSealedKey!, tvKeyPair: tvKp.keyPair),
      Uint8List.fromList(List<int>.filled(32, 9)),
    );
    expect(poppedResult, isTrue);
  });

  testWidgets('SyncSettingsScreen generates QR without prompting merge even with local shared mount', (tester) async {
    useLargeSurface(tester);
    final mockClient = MockClient((req) async {
      if (req.url.path == '/api/v1/auth/qr/create') {
        return http.Response(
          jsonEncode({'code': 0, 'session_id': 'qr-sess-1', 'expires_at_ms': 9999999999999}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (req.url.path == '/api/v1/auth/qr/poll') {
        return http.Response(
          jsonEncode({'code': 0, 'status': 'pending', 'expires_at_ms': 9999999999999}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
    final apiClient = SyncApiClient(httpClient: mockClient);
    addTearDown(apiClient.close);

    final h = await createSync(apiClient: apiClient);
    addTearDown(() async {
      h.sync.dispose();
      await h.manager.dispose();
      await h.db.close();
    });

    await h.manager.registry.upsert(
      const StorageMount(
        id: 'm-local-shared',
        kind: StorageKind.webdav,
        displayName: 'Local NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.99/dav'},
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncAndScanCoordinator>.value(
        value: h.sync,
        child: TranslationProvider(
          child: MaterialApp(
            theme: ThemeData(platform: TargetPlatform.windows),
            home: const SyncSettingsScreen(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text(t.sync.qrGenerate));
    await pumpUntil(tester, () => find.text(t.sync.qrRefreshButton).evaluate().isNotEmpty);
    await tester.pumpAndSettle();

    expect(find.text(t.sync.mergeDiffTitle), findsNothing);
    expect(find.text(t.sync.qrRefreshButton), findsOneWidget);
    expect(h.sync.isSignedIn, isFalse);
  });

  testWidgets('SyncSettingsScreen shows login failure without pre-auth merge popup', (tester) async {
    useLargeSurface(tester);
    final mockClient = MockClient((req) async {
      if (req.url.path == '/api/v1/auth/kdf') {
        return http.Response(
          jsonEncode({'code': 404, 'message': 'user not found'}),
          404,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
    final apiClient = SyncApiClient(httpClient: mockClient);
    addTearDown(apiClient.close);

    final h = await createSync(apiClient: apiClient);
    addTearDown(() async {
      h.sync.dispose();
      await h.manager.dispose();
      await h.db.close();
    });

    await h.manager.registry.upsert(
      const StorageMount(
        id: 'm-local-shared',
        kind: StorageKind.webdav,
        displayName: 'Local NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.99/dav'},
      ),
    );

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncAndScanCoordinator>.value(
        value: h.sync,
        child: TranslationProvider(child: const MaterialApp(home: SyncSettingsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'alice');
    await tester.enterText(fields.at(1), 'wrong-pass');
    await tester.tap(find.text(t.sync.login));
    await tester.pumpAndSettle();

    expect(find.text(t.sync.mergeDiffTitle), findsNothing);
    expect(find.textContaining('user not found'), findsOneWidget);
    expect(h.sync.isSignedIn, isFalse);
  });

  testWidgets('SyncSettingsScreen authenticates first, displays diff dialog, and revokes token on Cancel', (
    tester,
  ) async {
    useLargeSurface(tester);
    const kdfParams = SyncKdfParams(memoryKiB: 64, iterations: 1, parallelism: 1);
    final salt = SyncCrypto.randomBytes(16);
    final masterKey = SyncCrypto.generateMasterKey();
    final derived = await SyncCrypto.derivePasswordKeys(password: 'pw', salt: salt, params: kdfParams);
    final backup = await SyncCrypto.sealMasterKeyBackup(masterKey, derived.kek);

    String? revokedTokenId;
    final mockClient = MockClient((req) async {
      if (req.url.path == '/api/v1/auth/kdf') {
        return http.Response(
          jsonEncode({'code': 0, 'kdf_salt': base64Encode(salt), 'kdf_params': kdfParams.toJson()}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (req.url.path == '/api/v1/auth/login') {
        return http.Response(
          jsonEncode({
            'code': 0,
            'user_id': 'u-alice',
            'username': 'alice',
            'access_token': 'tok-temp-1',
            'kdf_salt': base64Encode(salt),
            'kdf_params': kdfParams.toJson(),
            'encrypted_master_key_backup': backup,
            'settings': {},
            'server_time_ms': 10000,
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (req.url.path == '/api/v1/user/me') {
        return http.Response(
          jsonEncode({
            'code': 0,
            'user_id': 'u-alice',
            'username': 'alice',
            'stats': {'sources': 1, 'works': 1, 'files': 1, 'work_prefs': 0, 'watch_progress': 0, 'lists': 0},
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (req.url.path == '/api/v1/sync/pull') {
        return http.Response(
          jsonEncode({
            'code': 0,
            'server_time_ms': 10000,
            'current_max_seq': 2,
            'next_seq': 2,
            'has_more': false,
            'reset_required': false,
            'user_settings': {},
            'data': {
              'sources': [
                {
                  'source_id': 'm-cloud-1',
                  'canonical_key': 'webdav://http://192.168.1.88/dav',
                  'name': 'Cloud NAS',
                  'protocol': 'webdav',
                  'is_deleted': false,
                },
              ],
              'works': [
                {'work_key': 'tmdb:movie:603', 'kind': 'movie', 'library_type': 'movie', 'is_deleted': false},
              ],
              'files': [],
              'work_prefs': [],
              'watch_progress': [],
              'lists': [],
            },
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (req.url.path == '/api/v1/user/devices' && req.method == 'GET') {
        return http.Response(
          jsonEncode({
            'code': 0,
            'devices': [
              {'token_id': 'tid-1', 'device_id': 'd1', 'is_current': true},
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      if (req.url.path == '/api/v1/user/devices/tid-1' && req.method == 'DELETE') {
        revokedTokenId = 'tid-1';
        return http.Response(
          jsonEncode({'code': 0, 'status': 'revoked'}),
          200,
          headers: {'content-type': 'application/json'},
        );
      }
      return http.Response('{}', 404);
    });
    final apiClient = SyncApiClient(httpClient: mockClient);
    addTearDown(apiClient.close);

    final h = await createSync(apiClient: apiClient);
    addTearDown(() async {
      h.sync.dispose();
      await h.manager.dispose();
      await h.db.close();
    });

    await h.manager.registry.upsert(
      const StorageMount(
        id: 'm-local-shared',
        kind: StorageKind.webdav,
        displayName: 'Local NAS',
        config: {MountKeys.baseUrl: 'http://192.168.1.99/dav'},
      ),
    );
    final itemId = await h.sync.repo.insertItem(
      LibraryItemsCompanion.insert(
        workKey: const Value('tmdb:movie:27205'),
        kind: LibraryKinds.movie,
        libraryType: LibraryTypes.movie,
        title: 'Inception',
        sortTitle: 'inception',
        tmdbId: const Value('27205'),
        metadataSource: const Value('tmdb'),
        scrapedAt: const Value(2000),
        addedAt: 2000,
        updatedAt: 2000,
      ),
    );
    final fid = await h.sync.repo.upsertFile(
      mountId: 'm-local-shared',
      path: '/Inception.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
    );
    await h.sync.repo.linkFile(fid, itemId);
    await h.sync.repo.updateFile(fid, const LibraryFilesCompanion(matchState: Value(LibraryMatchStates.matched)));

    await tester.pumpWidget(
      ChangeNotifierProvider<SyncAndScanCoordinator>.value(
        value: h.sync,
        child: TranslationProvider(child: const MaterialApp(home: SyncSettingsScreen())),
      ),
    );
    await tester.pumpAndSettle();

    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'alice');
    await tester.enterText(fields.at(1), 'pw');
    await tester.tap(find.text(t.sync.login));
    await tester.pumpAndSettle();

    expect(find.text(t.sync.mergeDiffTitle), findsOneWidget);
    expect(find.textContaining('Local NAS'), findsOneWidget);
    expect(find.textContaining('Cloud NAS'), findsOneWidget);
    expect(h.sync.isSignedIn, isFalse);

    await tester.tap(find.text(t.common.cancel));
    await tester.pumpAndSettle();

    expect(revokedTokenId, 'tid-1');
    expect(h.sync.isSignedIn, isFalse);
    expect((await h.manager.registry.list()).map((m) => m.displayName), ['Local NAS']);
  });
}
