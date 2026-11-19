import 'dart:convert';

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
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    CredentialVault.resetKeyForTesting();
    LocaleSettings.setLocaleSync(AppLocale.en);
  });

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
}
