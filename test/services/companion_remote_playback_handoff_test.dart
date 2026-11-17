import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plezy/database/app_database.dart';
import 'package:plezy/i18n/strings.g.dart';
import 'package:plezy/library/library_repository.dart';
import 'package:plezy/library/local_library_client.dart';
import 'package:plezy/media/media_backend.dart';
import 'package:plezy/media/media_item.dart';
import 'package:plezy/media/media_kind.dart';
import 'package:plezy/models/companion_remote/remote_command.dart';
import 'package:plezy/models/companion_remote/remote_playback_models.dart';
import 'package:plezy/models/companion_remote/remote_session.dart';
import 'package:plezy/providers/companion_remote_provider.dart';
import 'package:plezy/services/companion_remote/companion_remote_peer_service.dart';
import 'package:plezy/services/companion_remote/remote_auth_service.dart';
import 'package:plezy/services/companion_remote/remote_playback_launcher.dart';
import 'package:plezy/services/settings_service.dart';
import 'package:plezy/storage/mount_manager.dart';
import 'package:plezy/storage/mount_registry.dart';
import 'package:plezy/storage/storage_mount.dart';
import 'package:plezy/theme/mono_theme.dart';
import 'package:plezy/utils/platform_detector.dart';
import 'package:plezy/widgets/companion_remote/remote_device_menu.dart';
import 'package:provider/provider.dart';

import '../test_helpers/prefs.dart';

class _MenuFakeProvider extends CompanionRemoteProvider {
  _MenuFakeProvider({this.devices = const []});

  final List<RemoteOnlineDevice> devices;
  final List<String> quickToggledClientIds = [];

  @override
  bool get isCryptoReady => true;

  @override
  RemoteSessionStatus get status => RemoteSessionStatus.disconnected;

  @override
  List<RemoteOnlineDevice> get onlineTrustedDevices => devices;

  @override
  Future<void> refreshOnlineDeviceStatuses() async {}

  @override
  Future<void> toggleOnlineDevicePlayPause(DiscoveredHost host) async {
    quickToggledClientIds.add(host.clientId);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    resetSharedPreferencesForTest();
    SettingsService.resetForTesting();
    TvDetectionService.debugSetAppleTVOverride(null);
  });

  tearDown(() {
    TvDetectionService.debugSetAppleTVOverride(null);
  });

  test('encrypted HTTP /status & /action poll multiple hosts without disrupting active WebSocket', () async {
    final previousHttpOverrides = HttpOverrides.current;
    HttpOverrides.global = null;
    addTearDown(() => HttpOverrides.global = previousHttpOverrides);

    final auth = RemoteAuthService.instance;
    final sharedSecret = List<int>.generate(32, (i) => i + 1);
    final ctxTv = await auth.createLanPeerAuthContext(
      myDeviceId: 'tv-device',
      peerDeviceId: 'phone-device',
      sharedKey: sharedSecret,
    );
    final ctxPc = await auth.createLanPeerAuthContext(
      myDeviceId: 'pc-device',
      peerDeviceId: 'phone-device',
      sharedKey: List<int>.generate(32, (i) => i + 40),
    );
    final rogueCtx = await auth.createLanPeerAuthContext(
      myDeviceId: 'rogue-device',
      peerDeviceId: 'other-device',
      sharedKey: List<int>.filled(32, 99),
    );

    var tvPlaying = true;
    final hostTv = CompanionRemotePeerService();
    hostTv.hostStatusSnapshotBuilder = () => RemotePlayerSnapshot(
      active: true,
      stage: tvPlaying ? 'playing' : 'paused',
      title: 'Dune: Part Two',
      playing: tvPlaying,
      positionMs: 45000,
      durationMs: 9000000,
    );
    hostTv.onHostQuickAction = (action, _) async {
      if (action == 'playPause') tvPlaying = !tvPlaying;
      return hostTv.hostStatusSnapshotBuilder!();
    };

    final hostPc = CompanionRemotePeerService();
    hostPc.hostStatusSnapshotBuilder = () => RemotePlayerSnapshot.idle;

    final tvSession = await hostTv.createSessionForContexts('Living Room TV', 'android_tv', [ctxTv]);
    final pcSession = await hostPc.createSessionForContexts('Workstation PC', 'windows', [ctxPc]);
    addTearDown(() async {
      await hostTv.dispose();
      await hostPc.dispose();
    });

    // Connect a persistent /ws control session to hostTv.
    final wsClient = CompanionRemotePeerService();
    addTearDown(wsClient.dispose);
    var disconnectedUnexpectedly = false;
    wsClient.onDeviceDisconnected.listen((_) => disconnectedUnexpectedly = true);
    await wsClient.joinSessionWithContexts('Pixel Phone', 'android', '127.0.0.1:${tvSession.port}', [ctxTv]);
    expect(wsClient.isConnected, isTrue);

    final discoveredTv = DiscoveredHost(
      authContextId: ctxTv.id,
      clientId: 'tv-device',
      name: 'Living Room TV',
      platform: 'android_tv',
      port: tvSession.port,
      ips: ['127.0.0.1'],
    );
    final discoveredPc = DiscoveredHost(
      authContextId: ctxPc.id,
      clientId: 'pc-device',
      name: 'Workstation PC',
      platform: 'windows',
      port: pcSession.port,
      ips: ['127.0.0.1'],
    );

    // Simultaneous /status queries across both hosts.
    final tvSnap = await CompanionRemotePeerService.fetchHostStatus(host: discoveredTv, context: ctxTv);
    final pcSnap = await CompanionRemotePeerService.fetchHostStatus(host: discoveredPc, context: ctxPc);
    expect(tvSnap, isNotNull);
    expect(tvSnap!.active, isTrue);
    expect(tvSnap.title, 'Dune: Part Two');
    expect(tvSnap.playing, isTrue);
    expect(pcSnap, isNotNull);
    expect(pcSnap!.active, isFalse);

    // Quick Play/Pause over HTTP toggles TV state and returns fresh snapshot.
    final afterToggle = await CompanionRemotePeerService.sendHostQuickAction(
      host: discoveredTv,
      context: ctxTv,
      action: 'playPause',
    );
    expect(afterToggle?.playing, isFalse);
    expect(tvPlaying, isFalse);

    // Active /ws session stayed untouched.
    wsClient.sendCommand(const RemoteCommand(type: RemoteCommandType.ping));
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(disconnectedUnexpectedly, isFalse);
    expect(wsClient.isConnected, isTrue);

    // Untrusted context is rejected with 403 -> null.
    final rejected = await CompanionRemotePeerService.fetchHostStatus(host: discoveredTv, context: rogueCtx);
    expect(rejected, isNull);
  });

  test('buildRemoteMediaTarget & resolveRemoteMediaTargetLocally match across distinct SQLite IDs', () async {
    final prevWarn = driftRuntimeOptions.dontWarnAboutMultipleDatabases;
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    addTearDown(() => driftRuntimeOptions.dontWarnAboutMultipleDatabases = prevWarn);

    final dbA = AppDatabase.forTesting(NativeDatabase.memory());
    final dbB = AppDatabase.forTesting(NativeDatabase.memory());
    final repoA = LibraryRepository(dbA);
    final repoB = LibraryRepository(dbB);
    final registryA = MountRegistry(dbA);
    final registryB = MountRegistry(dbB);
    final mountManagerA = MountManager(registryA);
    final mountManagerB = MountManager(registryB);
    final clientB = LocalLibraryClient(repository: repoB, mounts: mountManagerB);
    addTearDown(() async {
      clientB.close();
      await mountManagerA.dispose();
      await mountManagerB.dispose();
      await dbA.close();
      await dbB.close();
    });

    const sharedMount = StorageMount(
      id: 'mount-webdav-1',
      kind: StorageKind.webdav,
      displayName: 'NAS Movies',
      config: {'baseUrl': 'https://nas.local/dav'},
    );
    await registryA.upsert(sharedMount);
    await registryB.upsert(sharedMount);
    // Different mount ID for fallback canonicalSourceKey + workKey test on show/episode
    await registryA.upsert(
      const StorageMount(
        id: 'mount-show-a',
        kind: StorageKind.smb,
        displayName: 'Shows',
        config: {'host': '192.168.1.50', 'share': 'media', 'rootPath': '/TV'},
      ),
    );
    await registryB.upsert(
      const StorageMount(
        id: 'mount-show-b',
        kind: StorageKind.smb,
        displayName: 'Shows',
        config: {'host': '192.168.1.50', 'share': 'media', 'rootPath': '/TV'},
      ),
    );

    // Offset dbB's auto-increment IDs so IDs diverge completely from dbA.
    await dbB.into(dbB.libraryItems).insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Placeholder 1',
            sortTitle: 'placeholder 1',
            addedAt: 1,
            updatedAt: 1,
          ),
        );
    await dbB.into(dbB.libraryItems).insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Placeholder 2',
            sortTitle: 'placeholder 2',
            addedAt: 1,
            updatedAt: 1,
          ),
        );

    final movieAId = await dbA.into(dbA.libraryItems).insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Inception',
            sortTitle: 'inception',
            tmdbId: const Value('27205'),
            addedAt: 100,
            updatedAt: 100,
          ),
        );
    final fileMovieA = await repoA.upsertFile(
      mountId: 'mount-webdav-1',
      path: '/SciFi/Inception.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
    );
    await repoA.linkFile(fileMovieA, movieAId);

    final movieBId = await dbB.into(dbB.libraryItems).insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.movie,
            libraryType: LibraryTypes.movie,
            title: 'Inception',
            sortTitle: 'inception',
            tmdbId: const Value('27205'),
            addedAt: 100,
            updatedAt: 100,
          ),
        );
    final fileMovieB = await repoB.upsertFile(
      mountId: 'mount-webdav-1',
      path: '/SciFi/Inception.mkv',
      role: LibraryFileRoles.video,
      scanId: 1,
    );
    await repoB.linkFile(fileMovieB, movieBId);
    expect(movieBId, isNot(equals(movieAId)));

    final targetMovie = await buildRemoteMediaTarget(
      metadata: MediaItem(
        id: '$movieAId',
        backend: MediaBackend.jellyfin,
        kind: MediaKind.movie,
        title: 'Inception',
        serverId: LocalLibraryClient.localServerId,
      ),
      db: dbA,
      mountManager: mountManagerA,
      positionMs: 185000,
      playbackRate: 1.25,
      streamQuality: '1080p',
    );
    expect(targetMovie.syncFileId, isNotNull);
    expect(targetMovie.workKey, 'tmdb:movie:27205');
    expect(targetMovie.positionMs, 185000);
    expect(targetMovie.playbackRate, 1.25);
    expect(targetMovie.streamQuality, '1080p');

    final resolvedMovie = await resolveRemoteMediaTargetLocally(
      target: targetMovie,
      db: dbB,
      localClient: clientB,
      mountManager: mountManagerB,
    );
    expect(resolvedMovie, isNotNull);
    expect(resolvedMovie!.item.id, '$movieBId');
    expect(resolvedMovie.mediaSourceId, '$fileMovieB');

    // Episode matching via workKey + season + episode across different mount IDs
    final showAId = await dbA.into(dbA.libraryItems).insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.show,
            libraryType: LibraryTypes.show,
            title: 'Game of Thrones',
            sortTitle: 'game of thrones',
            tmdbId: const Value('1399'),
            addedAt: 100,
            updatedAt: 100,
          ),
        );
    final seasonAId = await dbA.into(dbA.libraryItems).insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.season,
            libraryType: LibraryTypes.show,
            parentId: Value(showAId),
            showId: Value(showAId),
            seasonNumber: const Value(2),
            title: 'Season 2',
            sortTitle: 'season 2',
            addedAt: 100,
            updatedAt: 100,
          ),
        );
    final epAId = await dbA.into(dbA.libraryItems).insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.episode,
            libraryType: LibraryTypes.show,
            parentId: Value(seasonAId),
            showId: Value(showAId),
            seasonNumber: const Value(2),
            episodeNumber: const Value(5),
            title: 'The Ghost of Harrenhal',
            sortTitle: 'ghost of harrenhal',
            addedAt: 100,
            updatedAt: 100,
          ),
        );

    final showBId = await dbB.into(dbB.libraryItems).insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.show,
            libraryType: LibraryTypes.show,
            title: 'Game of Thrones',
            sortTitle: 'game of thrones',
            tmdbId: const Value('1399'),
            addedAt: 100,
            updatedAt: 100,
          ),
        );
    final seasonBId = await dbB.into(dbB.libraryItems).insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.season,
            libraryType: LibraryTypes.show,
            parentId: Value(showBId),
            showId: Value(showBId),
            seasonNumber: const Value(2),
            title: 'Season 2',
            sortTitle: 'season 2',
            addedAt: 100,
            updatedAt: 100,
          ),
        );
    final epBId = await dbB.into(dbB.libraryItems).insert(
          LibraryItemsCompanion.insert(
            kind: LibraryKinds.episode,
            libraryType: LibraryTypes.show,
            parentId: Value(seasonBId),
            showId: Value(showBId),
            seasonNumber: const Value(2),
            episodeNumber: const Value(5),
            title: 'The Ghost of Harrenhal',
            sortTitle: 'ghost of harrenhal',
            addedAt: 100,
            updatedAt: 100,
          ),
        );

    final epTarget = await buildRemoteMediaTarget(
      metadata: MediaItem.jellyfin(
        id: '$epAId',
        kind: MediaKind.episode,
        title: 'The Ghost of Harrenhal',
        grandparentTitle: 'Game of Thrones',
        parentIndex: 2,
        index: 5,
        serverId: LocalLibraryClient.localServerId,
      ),
      db: dbA,
      mountManager: mountManagerA,
      positionMs: 92000,
    );
    expect(epTarget.workKey, 'tmdb:show:1399');

    final resolvedEp = await resolveRemoteMediaTargetLocally(
      target: epTarget,
      db: dbB,
      localClient: clientB,
      mountManager: mountManagerB,
    );
    expect(resolvedEp, isNotNull);
    expect(resolvedEp!.item.id, '$epBId');
  });

  testWidgets('PopMenus show empty hint when offline and live status + quick play/pause when online', (tester) async {
    final emptyProvider = _MenuFakeProvider();
    addTearDown(emptyProvider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<CompanionRemoteProvider>.value(
        value: emptyProvider,
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(showRemotePlayPickerMenu(context)),
                child: const Text('Pick'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Pick'));
    await tester.pumpAndSettle();
    expect(find.text(t.companionRemote.noOnlineDevices), findsOneWidget);

    await tester.tapAt(const Offset(5, 5));
    await tester.pumpAndSettle();

    final hostTv = DiscoveredHost(
      authContextId: 'ctx-1',
      clientId: 'tv-1',
      name: 'Bedroom TV',
      platform: 'android_tv',
      port: 48632,
      ips: ['192.168.1.20'],
    );
    final activeProvider = _MenuFakeProvider(
      devices: [
        RemoteOnlineDevice(
          host: hostTv,
          snapshot: const RemotePlayerSnapshot(
            active: true,
            stage: 'playing',
            mediaKind: 'episode',
            seriesTitle: 'Severance',
            seasonNumber: 1,
            episodeNumber: 3,
            title: 'In Perpetuity',
            playing: true,
            positionMs: 65000,
            durationMs: 3000000,
          ),
        ),
      ],
    );
    addTearDown(activeProvider.dispose);

    await tester.pumpWidget(
      ChangeNotifierProvider<CompanionRemoteProvider>.value(
        value: activeProvider,
        child: MaterialApp(
          theme: monoTheme(MonoPalette.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(showRemoteDevicesStatusMenu(context)),
                child: const Text('Devices'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Devices'));
    await tester.pumpAndSettle();

    expect(find.text('Bedroom TV'), findsOneWidget);
    expect(find.textContaining('Severance · S01E03 In Perpetuity'), findsOneWidget);
    expect(find.byTooltip(t.companionRemote.paused), findsOneWidget);

    await tester.tap(find.byTooltip(t.companionRemote.paused));
    await tester.pump();
    expect(activeProvider.quickToggledClientIds, ['tv-1']);
  });

  test('enableCompanionRemoteServer defaults true on Desktop and TV, false on Mobile', () async {
    expect(SettingsService.defaultEnableCompanionRemoteServerFor(isDesktop: true, isTv: false), isTrue);
    expect(SettingsService.defaultEnableCompanionRemoteServerFor(isDesktop: false, isTv: true), isTrue);
    expect(SettingsService.defaultEnableCompanionRemoteServerFor(isDesktop: false, isTv: false), isFalse);

    TvDetectionService.debugSetAppleTVOverride(true);
    final settings = await SettingsService.getInstance();
    expect(settings.read(SettingsService.enableCompanionRemoteServer), isTrue);
  });
}
