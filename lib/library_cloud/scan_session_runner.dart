import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter/foundation.dart';

import '../storage/drivers/quark_storage_driver.dart';
import '../storage/storage_driver.dart';
import '../storage/storage_mount.dart';
import '../storage/storage_path.dart';
import 'cloud_api_client.dart';

class CloudScanProgress {
  const CloudScanProgress({
    required this.sourceId,
    this.folderId,
    required this.sessionId,
    required this.directoriesVisited,
    required this.filesReported,
    required this.batchesSent,
    this.scanType = 'full',
    this.filesFound = 0,
    this.filesAdded = 0,
    this.filesChanged = 0,
    this.filesMissing = 0,
    this.completed = false,
    this.cancelled = false,
    this.cancelling = false,
    this.targetLabel,
    this.error,
    this.updatedAtMs = 0,
  });

  final String sourceId;
  final String? folderId;
  final String sessionId;
  final int directoriesVisited;
  final int filesFound;
  final int filesReported;
  final int batchesSent;
  final String scanType;
  final int filesAdded;
  final int filesChanged;
  final int filesMissing;
  final bool completed;
  final bool cancelled;
  final bool cancelling;
  final String? targetLabel;
  final String? error;
  final int updatedAtMs;

  CloudScanProgress copyWith({
    String? sessionId,
    int? directoriesVisited,
    int? filesFound,
    int? filesReported,
    int? batchesSent,
    String? scanType,
    int? filesAdded,
    int? filesChanged,
    int? filesMissing,
    bool? completed,
    bool? cancelled,
    bool? cancelling,
    String? targetLabel,
    String? error,
    bool clearError = false,
    int? updatedAtMs,
  }) => CloudScanProgress(
    sourceId: sourceId,
    folderId: folderId,
    sessionId: sessionId ?? this.sessionId,
    directoriesVisited: directoriesVisited ?? this.directoriesVisited,
    filesFound: filesFound ?? this.filesFound,
    filesReported: filesReported ?? this.filesReported,
    batchesSent: batchesSent ?? this.batchesSent,
    scanType: scanType ?? this.scanType,
    filesAdded: filesAdded ?? this.filesAdded,
    filesChanged: filesChanged ?? this.filesChanged,
    filesMissing: filesMissing ?? this.filesMissing,
    completed: completed ?? this.completed,
    cancelled: cancelled ?? this.cancelled,
    cancelling: cancelling ?? this.cancelling,
    targetLabel: targetLabel ?? this.targetLabel,
    error: clearError ? null : (error ?? this.error),
    updatedAtMs: updatedAtMs ?? this.updatedAtMs,
  );
}

class CloudScanSessionRecord {
  const CloudScanSessionRecord({
    required this.id,
    required this.sourceId,
    this.folderId,
    required this.type,
    required this.status,
    required this.startedAt,
    this.finishedAt,
    required this.filesReported,
    required this.filesAdded,
    required this.filesChanged,
    required this.filesMissing,
  });

  final String id;
  final String sourceId;
  final String? folderId;
  final String type;
  final String status;
  final int startedAt;
  final int? finishedAt;
  final int filesReported;
  final int filesAdded;
  final int filesChanged;
  final int filesMissing;

  bool get isCompleted => status == 'completed';

  factory CloudScanSessionRecord.fromJson(Map<String, dynamic> json) {
    final rawFolder = json['folder_id'];
    final folder = rawFolder is String && rawFolder.trim().isNotEmpty ? rawFolder.trim() : null;
    return CloudScanSessionRecord(
      id: json['id'] as String? ?? '',
      sourceId: json['source_id'] as String? ?? '',
      folderId: folder,
      type: json['type'] as String? ?? 'full',
      status: (json['status'] as String? ?? '').toLowerCase(),
      startedAt: (json['started_at'] as num?)?.toInt() ?? 0,
      finishedAt: (json['finished_at'] as num?)?.toInt(),
      filesReported: (json['files_reported'] as num?)?.toInt() ?? 0,
      filesAdded: (json['files_added'] as num?)?.toInt() ?? 0,
      filesChanged: (json['files_changed'] as num?)?.toInt() ?? 0,
      filesMissing: (json['files_missing'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Client-side scanner & idempotent batch ingest runner for `media_library` (S3).
///
/// Walks configured folders using a local [StorageDriver] (Quark / WebDAV / SMB),
/// streams small batches with gzip compression as directories are discovered,
/// uploads missing sidecar NFO/artwork bytes when requested by the server,
/// and preserves live scan progress globally across route navigation.
class CloudScanSessionRunner extends ChangeNotifier {
  CloudScanSessionRunner({
    required this.api,
    this.batchSize = 50,
    this.flushInterval = const Duration(seconds: 3),
    this.progressReportInterval = const Duration(seconds: 4),
    this.maxNfoBytes = 64 * 1024,
    this.maxArtworkBytes = 300 * 1024,
    this.onBatchCommitted,
    this.onScanFinished,
  });

  final CloudApiClient api;
  final int batchSize;
  final Duration flushInterval;
  final Duration progressReportInterval;
  final int maxNfoBytes;
  final int maxArtworkBytes;
  final void Function(String sourceId, int added, int changed)? onBatchCommitted;
  final void Function(CloudScanProgress summary)? onScanFinished;

  final Set<String> _activeTasks = <String>{};
  final Set<String> _cancelledTasks = <String>{};
  final Map<String, CloudScanProgress> _progressByKey = <String, CloudScanProgress>{};
  final Map<String, String> _errorByKey = <String, String>{};
  bool _disposed = false;

  static String taskKey(String sourceId, [String? folderId]) =>
      (folderId != null && folderId.isNotEmpty) ? '$sourceId::$folderId' : sourceId;

  bool isScanning(String sourceId, {String? folderId}) => _activeTasks.contains(taskKey(sourceId, folderId));

  bool isCancelling(String sourceId, {String? folderId}) => _cancelledTasks.contains(taskKey(sourceId, folderId));

  bool isAnyScanning(String sourceId) =>
      _activeTasks.contains(sourceId) || _activeTasks.any((k) => k.startsWith('$sourceId::'));

  bool get hasActiveScans => _activeTasks.isNotEmpty;

  List<CloudScanProgress> get activeScans => [
    for (final key in _activeTasks) ?_progressByKey[key],
  ];

  CloudScanProgress? progressOf(String sourceId, {String? folderId}) => _progressByKey[taskKey(sourceId, folderId)];

  String? errorOf(String sourceId, {String? folderId}) => _errorByKey[taskKey(sourceId, folderId)];

  ({String key, String message})? get latestError {
    if (_errorByKey.isEmpty) return null;
    final last = _errorByKey.entries.last;
    return (key: last.key, message: last.value);
  }

  void clearError(String sourceId, {String? folderId}) {
    final key = taskKey(sourceId, folderId);
    if (_errorByKey.remove(key) != null) {
      _notify();
    }
  }

  void cancelScan(String sourceId, {String? folderId}) {
    final key = taskKey(sourceId, folderId);
    if (!_activeTasks.contains(key)) return;
    if (_cancelledTasks.add(key)) {
      final cur = _progressByKey[key];
      if (cur != null) {
        _progressByKey[key] = cur.copyWith(
          cancelling: true,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      _notify();
    }
  }

  void _notify() {
    if (!_disposed) {
      notifyListeners();
    }
  }

  /// Fetches recent scan sessions for [sourceId] (newest first) from the server.
  Future<List<CloudScanSessionRecord>> listRecentSessions(String sourceId) async {
    final resp = await api.getJson('/api/v1/sources/${Uri.encodeComponent(sourceId)}/scan-sessions');
    final raw = resp['sessions'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) CloudScanSessionRecord.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  /// Runs a full, incremental, or single-folder scan session for [sourceId]
  /// using [driver].
  ///
  /// Throws [StateError] if this device is already scanning the same target.
  Future<CloudScanProgress> runScan({
    required String sourceId,
    required StorageDriver driver,
    String scanType = 'full',
    String? folderId,
    String? targetLabel,
    bool? readSidecars,
    void Function(CloudScanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final key = taskKey(sourceId, folderId);
    if (!_activeTasks.add(key)) {
      throw StateError('Scan already running locally for $key');
    }
    _cancelledTasks.remove(key);
    _errorByKey.remove(key);

    final shouldReadSidecars = readSidecars ?? driver.kind != StorageKind.quark;
    String sessionId = '';
    var dirsVisited = 0;
    var filesFound = 0;
    var filesReported = 0;
    var batchesSent = 0;
    var filesAdded = 0;
    var filesChanged = 0;

    bool checkCancelled() => _cancelledTasks.contains(key) || (isCancelled?.call() == true);

    void publish(CloudScanProgress p) {
      _progressByKey[key] = p;
      onProgress?.call(p);
      _notify();
    }

    publish(
      CloudScanProgress(
        sourceId: sourceId,
        folderId: folderId,
        sessionId: '',
        directoriesVisited: 0,
        filesFound: 0,
        filesReported: 0,
        batchesSent: 0,
        scanType: scanType,
        targetLabel: targetLabel,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      ),
    );

    try {
      var capturedWatermark = 0;
      if (driver is QuarkStorageDriver && driver.supportsIncremental) {
        try {
          final head = await driver.searchUpdatedPage(1, size: 1);
          capturedWatermark = head.where((row) => !row.entry.isDirectory).firstOrNull?.updatedAt ?? 0;
        } catch (_) {
          // Best-effort baseline capture for later incremental checks.
        }
      }

      final sessionResp = await api.postJson(
        '/api/v1/sources/${Uri.encodeComponent(sourceId)}/scan-sessions',
        body: {
          'type': scanType,
          if (folderId != null && folderId.isNotEmpty) 'folder_id': folderId,
        },
      );
      final sessMap = Map<String, dynamic>.from(sessionResp['session'] as Map? ?? const {});
      sessionId = sessMap['id'] as String? ?? '';
      if (sessionId.isEmpty) {
        throw StateError('Server did not return a scan session id');
      }

      final foldersRaw = sessMap['folders'] as List? ?? const [];
      final folderScopes = <({String path, List<String> excludes})>[
        for (final f in foldersRaw)
          if (f is Map)
            (
              path: (f['path'] as String? ?? '/').trim(),
              excludes: [for (final ex in (f['exclude_paths'] as List? ?? const [])) '$ex'],
            ),
      ];

      final pendingUpserts = <Map<String, dynamic>>[];
      final sidecarBytesByHash = <String, ({String contentType, Uint8List bytes})>{};
      var batchNo = 0;
      var lastFlushAt = DateTime.now();
      var lastServerProgressAt = DateTime.fromMillisecondsSinceEpoch(0);

      Future<void> flushBatch() async {
        if (pendingUpserts.isEmpty) return;
        batchNo++;
        final chunk = List<Map<String, dynamic>>.from(pendingUpserts);
        pendingUpserts.clear();

        final resp = await _postBatchWithRetry(sessionId, {
          'batch_no': batchNo,
          'upserts': chunk,
        });

        lastFlushAt = DateTime.now();
        batchesSent++;
        filesReported += chunk.length;

        var batchAdded = 0;
        var batchChanged = 0;
        final receipt = resp['receipt'];
        if (receipt is Map) {
          batchAdded = (receipt['added'] as num?)?.toInt() ?? 0;
          batchChanged = (receipt['changed'] as num?)?.toInt() ?? 0;
          filesAdded += batchAdded;
          filesChanged += batchChanged;
          final missing = receipt['missing_sidecars'];
          if (missing is List && missing.isNotEmpty) {
            for (final rawHash in missing) {
              final hash = '$rawHash';
              final ref = sidecarBytesByHash[hash];
              if (ref == null) continue;
              await _uploadSidecarBytes(hash, ref.bytes, ref.contentType);
            }
          }
        }

        if (batchAdded > 0 || batchChanged > 0) {
          onBatchCommitted?.call(sourceId, batchAdded, batchChanged);
        }

        publish(
          CloudScanProgress(
            sourceId: sourceId,
            folderId: folderId,
            sessionId: sessionId,
            directoriesVisited: dirsVisited,
            filesFound: filesFound,
            filesReported: filesReported,
            batchesSent: batchesSent,
            scanType: scanType,
            filesAdded: filesAdded,
            filesChanged: filesChanged,
            cancelling: checkCancelled(),
            targetLabel: targetLabel,
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }

      Future<void> reportServerProgressIfDue(int pendingQueueLen) async {
        if (sessionId.isEmpty) return;
        final now = DateTime.now();
        if (now.difference(lastServerProgressAt) < progressReportInterval) return;
        lastServerProgressAt = now;
        final pct = pendingQueueLen == 0
            ? 95
            : ((dirsVisited / (dirsVisited + pendingQueueLen)) * 90).round().clamp(1, 95);
        try {
          await api.postJson(
            '/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/progress',
            body: {
              'progress_pct': pct,
              'files_reported': filesReported,
            },
          );
        } catch (_) {
          // Non-fatal informational progress update.
        }
      }

      Future<CloudScanProgress> finishCancelled() async {
        if (pendingUpserts.isNotEmpty) {
          try {
            await flushBatch();
          } catch (_) {}
        }
        try {
          await api.postJson('/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/cancel');
        } catch (_) {}
        _activeTasks.remove(key);
        _cancelledTasks.remove(key);
        final cancelledProgress = CloudScanProgress(
          sourceId: sourceId,
          folderId: folderId,
          sessionId: sessionId,
          directoriesVisited: dirsVisited,
          filesFound: filesFound,
          filesReported: filesReported,
          batchesSent: batchesSent,
          scanType: scanType,
          filesAdded: filesAdded,
          filesChanged: filesChanged,
          completed: false,
          cancelled: true,
          cancelling: false,
          targetLabel: targetLabel,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
        publish(cancelledProgress);
        onScanFinished?.call(cancelledProgress);
        return cancelledProgress;
      }

      for (final scope in folderScopes) {
        final queue = Queue<({String path, StorageEntry? entry})>()..add((path: scope.path, entry: null));
        final visited = <String>{};

        while (queue.isNotEmpty) {
          if (checkCancelled()) {
            return await finishCancelled();
          }

          final current = queue.removeFirst();
          if (!visited.add(current.path)) continue;
          if (_isExcluded(current.path, scope.excludes)) continue;

          final children = await driver.list(current.path, parent: current.entry);
          dirsVisited++;

          publish(
            CloudScanProgress(
              sourceId: sourceId,
              folderId: folderId,
              sessionId: sessionId,
              directoriesVisited: dirsVisited,
              filesFound: filesFound,
              filesReported: filesReported,
              batchesSent: batchesSent,
              scanType: scanType,
              filesAdded: filesAdded,
              filesChanged: filesChanged,
              cancelling: checkCancelled(),
              targetLabel: targetLabel,
              updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            ),
          );
          unawaited(reportServerProgressIfDue(queue.length));

          for (final child in children) {
            if (checkCancelled()) {
              return await finishCancelled();
            }
            if (_isExcluded(child.path, scope.excludes)) continue;
            if (child.isDirectory) {
              queue.add((path: child.path, entry: child));
              continue;
            }

            final item = <String, dynamic>{
              'path': child.path,
              if (child.id != null && child.id!.isNotEmpty) 'remote_id': child.id,
              if (child.size != null) 'size': child.size,
              if (child.modifiedAt != null) 'mtime_s': child.modifiedAt!.millisecondsSinceEpoch ~/ 1000,
              if (child.createdAt != null) 'ctime_s': child.createdAt!.millisecondsSinceEpoch ~/ 1000,
            };

            if (shouldReadSidecars) {
              final sidecarSpec = _classifySidecar(child);
              if (sidecarSpec != null && (child.size == null || child.size! <= sidecarSpec.maxBytes)) {
                final bytes = await _readSmallFile(driver, child, sidecarSpec.maxBytes);
                if (bytes != null) {
                  final hash = crypto.sha256.convert(bytes).toString();
                  item['sidecar_hash'] = hash;
                  sidecarBytesByHash[hash] = (
                    contentType: sidecarSpec.contentType,
                    bytes: bytes,
                  );
                }
              }
            }

            filesFound++;
            pendingUpserts.add(item);
            if (pendingUpserts.length >= batchSize || DateTime.now().difference(lastFlushAt) >= flushInterval) {
              await flushBatch();
              await reportServerProgressIfDue(queue.length);
            }
          }

          if (pendingUpserts.isNotEmpty &&
              (batchesSent == 0 || DateTime.now().difference(lastFlushAt) >= flushInterval)) {
            await flushBatch();
            await reportServerProgressIfDue(queue.length);
          }
        }
      }

      if (checkCancelled()) {
        return await finishCancelled();
      }

      await flushBatch();

      final completeResp = await api.postJson(
        '/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/complete',
        body: {
          'complete': true,
          if (capturedWatermark > 0) 'new_watermark': capturedWatermark,
        },
      );
      final completeMap = completeResp['result'] is Map
          ? Map<String, dynamic>.from(completeResp['result'] as Map)
          : completeResp;
      final missingCount = (completeMap['missing_count'] as num?)?.toInt() ??
          (completeMap['files_missing'] as num?)?.toInt() ??
          0;

      _activeTasks.remove(key);
      _cancelledTasks.remove(key);

      final done = CloudScanProgress(
        sourceId: sourceId,
        folderId: folderId,
        sessionId: sessionId,
        directoriesVisited: dirsVisited,
        filesFound: filesFound,
        filesReported: filesReported,
        batchesSent: batchesSent,
        scanType: scanType,
        filesAdded: filesAdded,
        filesChanged: filesChanged,
        filesMissing: missingCount,
        completed: true,
        cancelling: false,
        targetLabel: targetLabel,
        updatedAtMs: DateTime.now().millisecondsSinceEpoch,
      );
      publish(done);
      onScanFinished?.call(done);
      return done;
    } catch (e) {
      if (sessionId.isNotEmpty) {
        try {
          await api.postJson(
            '/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/complete',
            body: {'complete': false},
          );
        } catch (_) {}
      }
      final msg = e is CloudApiException ? e.message : '$e';
      _errorByKey[key] = msg;
      final prev = _progressByKey[key];
      _activeTasks.remove(key);
      _cancelledTasks.remove(key);
      if (prev != null && !prev.completed && !prev.cancelled) {
        _progressByKey[key] = prev.copyWith(
          cancelling: false,
          error: msg,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      _notify();
      rethrow;
    } finally {
      final changed = _activeTasks.remove(key);
      final cancelledChanged = _cancelledTasks.remove(key);
      if (changed || cancelledChanged) {
        _notify();
      }
    }
  }

  /// Runs an incremental Quark scan session for [sourceId], fetching only files
  /// updated since the server's `incremental_watermark` (or [fallbackWatermarkMs])
  /// via `/file/search` and refreshing only the touched directories.
  Future<CloudScanProgress> runQuarkIncrementalScan({
    required String sourceId,
    required StorageDriver driver,
    int fallbackWatermarkMs = 0,
    int knownServerWatermark = 0,
    Map<String, int?>? knownFileMtimesByRemoteId,
    String? targetLabel,
    void Function(CloudScanProgress progress)? onProgress,
    bool Function()? isCancelled,
    Future<List<({StorageEntry entry, String parentId, int updatedAt})>> Function(int page, {int size})?
        searchUpdatedPageOverride,
    Future<List<({String id, String name})>> Function(String id)? folderAncestryOverride,
    String? rootFolderIdOverride,
  }) async {
    final key = taskKey(sourceId);
    if (isAnyScanning(sourceId) || !_activeTasks.add(key)) {
      throw StateError('Scan already running locally for $sourceId');
    }
    _cancelledTasks.remove(key);
    _errorByKey.remove(key);

    final quarkDriver = driver is QuarkStorageDriver ? driver : null;
    final searchFn =
        searchUpdatedPageOverride ??
        (quarkDriver != null
            ? quarkDriver.searchUpdatedPage
            : throw StateError('Quark driver required for incremental scan'));
    final ancestryFn =
        folderAncestryOverride ??
        (quarkDriver != null
            ? quarkDriver.folderAncestry
            : throw StateError('Quark driver required for incremental scan'));
    final rootFolderId = rootFolderIdOverride ?? quarkDriver?.rootFolderId ?? QuarkStorageDriver.defaultRootFolderId;

    String sessionId = '';
    var dirsVisited = 0;
    var filesFound = 0;
    var filesReported = 0;
    var batchesSent = 0;
    var filesAdded = 0;
    var filesChanged = 0;
    var filesMissing = 0;

    bool checkCancelled() => _cancelledTasks.contains(key) || (isCancelled?.call() == true);

    void publish(CloudScanProgress p) {
      _progressByKey[key] = p;
      onProgress?.call(p);
      _notify();
    }

    CloudScanProgress snapshotProgress({
      bool completed = false,
      bool cancelled = false,
      bool? cancelling,
      String? error,
    }) => CloudScanProgress(
      sourceId: sourceId,
      sessionId: sessionId,
      directoriesVisited: dirsVisited,
      filesFound: filesFound,
      filesReported: filesReported,
      batchesSent: batchesSent,
      scanType: 'incremental',
      filesAdded: filesAdded,
      filesChanged: filesChanged,
      filesMissing: filesMissing,
      completed: completed,
      cancelled: cancelled,
      cancelling: cancelling ?? (!completed && !cancelled && checkCancelled()),
      targetLabel: targetLabel,
      error: error,
      updatedAtMs: DateTime.now().millisecondsSinceEpoch,
    );

    publish(snapshotProgress());

    try {
      const overlapMs = 60 * 1000;

      Future<({int latestWatermark, List<({StorageEntry entry, String parentId, int updatedAt})> changedRows})?>
          collectChangedRows(int watermarkMs) async {
        final threshold = watermarkMs - overlapMs;
        var latestWatermark = watermarkMs;
        final changedRows = <({StorageEntry entry, String parentId, int updatedAt})>[];

        for (var page = 1; page <= 20; page++) {
          if (checkCancelled()) return null;
          final rows = await searchFn(page, size: QuarkStorageDriver.searchPageSize);
          int? lastFileTs;
          for (final row in rows) {
            if (row.entry.isDirectory) continue;
            lastFileTs = row.updatedAt;
            if (row.updatedAt > latestWatermark) latestWatermark = row.updatedAt;
            if (row.updatedAt >= threshold && row.parentId.isNotEmpty) {
              final rid = row.entry.id;
              if (rid != null &&
                  knownFileMtimesByRemoteId != null &&
                  knownFileMtimesByRemoteId.containsKey(rid)) {
                var knownMtime = knownFileMtimesByRemoteId[rid];
                if (knownMtime != null && knownMtime > 0) {
                  if (row.updatedAt >= 100000000000 && knownMtime < 100000000000) {
                    knownMtime *= 1000;
                  }
                  if ((row.updatedAt - knownMtime).abs() <= 1000) {
                    continue;
                  }
                }
              }
              changedRows.add(row);
            }
          }
          if (rows.length < QuarkStorageDriver.searchPageSize || (lastFileTs != null && lastFileTs < threshold)) {
            break;
          }
        }
        return (latestWatermark: latestWatermark, changedRows: changedRows);
      }

      // Pre-check Quark updated files BEFORE opening a server scan session so a
      // zero-change check creates zero empty scan-session records on the server.
      final preWatermark = knownServerWatermark > 0 ? knownServerWatermark : fallbackWatermarkMs;
      ({int latestWatermark, List<({StorageEntry entry, String parentId, int updatedAt})> changedRows})? preSearch;
      if (preWatermark > 0) {
        preSearch = await collectChangedRows(preWatermark);
        if (preSearch == null || checkCancelled()) {
          _activeTasks.remove(key);
          _cancelledTasks.remove(key);
          final cancelled = snapshotProgress(cancelled: true, cancelling: false);
          publish(cancelled);
          onScanFinished?.call(cancelled);
          return cancelled;
        }
        if (preSearch.changedRows.isEmpty &&
            knownServerWatermark > 0 &&
            preSearch.latestWatermark <= knownServerWatermark) {
          _activeTasks.remove(key);
          _cancelledTasks.remove(key);
          final done = snapshotProgress(completed: true, cancelling: false);
          publish(done);
          onScanFinished?.call(done);
          return done;
        }
      }

      final sessionResp = await api.postJson(
        '/api/v1/sources/${Uri.encodeComponent(sourceId)}/scan-sessions',
        body: {'type': 'incremental'},
      );
      final sessMap = Map<String, dynamic>.from(sessionResp['session'] as Map? ?? const {});
      sessionId = sessMap['id'] as String? ?? '';
      if (sessionId.isEmpty) {
        throw StateError('Server did not return a scan session id');
      }

      final foldersRaw = sessMap['folders'] as List? ?? const [];
      final folderScopes = <({String path, List<String> excludes})>[
        for (final f in foldersRaw)
          if (f is Map)
            (
              path: StoragePath.normalize((f['path'] as String? ?? StoragePath.root).trim()),
              excludes: [
                for (final ex in (f['exclude_paths'] as List? ?? const []))
                  if ('$ex'.trim().isNotEmpty) StoragePath.normalize('$ex'),
              ],
            ),
      ];
      final serverWatermark = (sessMap['incremental_watermark'] as num?)?.toInt() ?? 0;
      final effectiveWatermark = serverWatermark > 0 ? serverWatermark : fallbackWatermarkMs;

      Future<CloudScanProgress> finishCancelled(
        List<Map<String, dynamic>> pendingUpserts,
        List<Map<String, dynamic>> pendingRemoved,
      ) async {
        try {
          if (pendingUpserts.isNotEmpty || pendingRemoved.isNotEmpty) {
            await api.postJson(
              '/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/batches',
              gzipBody: true,
              body: {
                'batch_no': 1,
                'upserts': pendingUpserts,
                if (pendingRemoved.isNotEmpty) 'removed': pendingRemoved,
              },
            );
          }
        } catch (_) {}
        try {
          await api.postJson('/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/cancel');
        } catch (_) {}
        _activeTasks.remove(key);
        _cancelledTasks.remove(key);
        final cancelled = snapshotProgress(cancelled: true, cancelling: false);
        publish(cancelled);
        onScanFinished?.call(cancelled);
        return cancelled;
      }

      // First incremental baseline capture if neither server nor local cache has a watermark yet.
      if (effectiveWatermark <= 0) {
        final head = await searchFn(1, size: 1);
        final headWatermark = head.where((row) => !row.entry.isDirectory).firstOrNull?.updatedAt ?? 0;
        await api.postJson(
          '/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/complete',
          body: {'complete': true, if (headWatermark > 0) 'new_watermark': headWatermark},
        );
        _activeTasks.remove(key);
        _cancelledTasks.remove(key);
        final done = snapshotProgress(completed: true, cancelling: false);
        publish(done);
        onScanFinished?.call(done);
        return done;
      }

      final searchRes = (preSearch != null && effectiveWatermark >= preWatermark)
          ? preSearch
          : await collectChangedRows(effectiveWatermark);
      if (searchRes == null || checkCancelled()) {
        return await finishCancelled(const [], const []);
      }
      final latestWatermark = searchRes.latestWatermark;
      final changedRows = searchRes.changedRows;

      final pathsByFolderId = <String, String?>{rootFolderId: StoragePath.root};
      final changedDirs = <String, String>{};
      final pendingRemoved = <Map<String, dynamic>>[];

      for (final row in changedRows) {
        if (checkCancelled()) return await finishCancelled(const [], const []);
        final parentPath = pathsByFolderId.containsKey(row.parentId)
            ? pathsByFolderId[row.parentId]
            : pathsByFolderId[row.parentId] = await _resolveQuarkFolderPath(row.parentId, rootFolderId, ancestryFn);
        if (parentPath == null) {
          if (row.entry.id?.isNotEmpty == true) {
            pendingRemoved.add({'remote_id': row.entry.id});
          }
          continue;
        }
        final filePath = StoragePath.normalize(StoragePath.join(parentPath, row.entry.name));
        if (!_isPathInFolderScopes(filePath, folderScopes)) {
          if (row.entry.id?.isNotEmpty == true) {
            pendingRemoved.add({'remote_id': row.entry.id});
          }
          continue;
        }
        changedDirs.putIfAbsent(row.parentId, () => parentPath);
      }

      final pendingUpserts = <Map<String, dynamic>>[];
      var batchNo = 0;
      var lastFlushAt = DateTime.now();

      Future<void> flushIncBatch({bool includeRemoved = false}) async {
        final removedChunk = includeRemoved && pendingRemoved.isNotEmpty
            ? List<Map<String, dynamic>>.from(pendingRemoved.take(batchSize))
            : const <Map<String, dynamic>>[];
        if (removedChunk.isNotEmpty) {
          pendingRemoved.removeRange(0, removedChunk.length);
        }
        final upsertsChunk = List<Map<String, dynamic>>.from(pendingUpserts);
        pendingUpserts.clear();
        if (upsertsChunk.isEmpty && removedChunk.isEmpty) return;

        batchNo++;
        final resp = await _postBatchWithRetry(sessionId, {
          'batch_no': batchNo,
          'upserts': upsertsChunk,
          if (removedChunk.isNotEmpty) 'removed': removedChunk,
        });
        lastFlushAt = DateTime.now();
        batchesSent++;
        filesReported += upsertsChunk.length;

        final receipt = resp['receipt'];
        var batchAdded = 0;
        var batchChanged = 0;
        var batchRemoved = 0;
        if (receipt is Map) {
          batchAdded = (receipt['added'] as num?)?.toInt() ?? 0;
          batchChanged = (receipt['changed'] as num?)?.toInt() ?? 0;
          batchRemoved = (receipt['removed'] as num?)?.toInt() ?? 0;
          filesAdded += batchAdded;
          filesChanged += batchChanged;
          filesMissing += batchRemoved;
        }
        if (batchAdded > 0 || batchChanged > 0 || batchRemoved > 0) {
          onBatchCommitted?.call(sourceId, batchAdded, batchChanged + batchRemoved);
        }
        publish(snapshotProgress());
      }

      for (final entry in changedDirs.entries) {
        if (checkCancelled()) return await finishCancelled(pendingUpserts, pendingRemoved);
        final dirEntry = StorageEntry(
          id: entry.key,
          path: entry.value,
          name: StoragePath.name(entry.value),
          isDirectory: true,
        );
        final children = await driver.list(entry.value, parent: dirEntry);
        dirsVisited++;
        publish(snapshotProgress());

        for (final child in children) {
          if (checkCancelled()) return await finishCancelled(pendingUpserts, pendingRemoved);
          if (child.isDirectory) continue;
          final normChildPath = StoragePath.normalize(child.path);
          if (!_isPathInFolderScopes(normChildPath, folderScopes)) continue;

          pendingUpserts.add({
            'path': normChildPath,
            if (child.id != null && child.id!.isNotEmpty) 'remote_id': child.id,
            if (child.size != null) 'size': child.size,
            if (child.modifiedAt != null) 'mtime_s': child.modifiedAt!.millisecondsSinceEpoch ~/ 1000,
            if (child.createdAt != null) 'ctime_s': child.createdAt!.millisecondsSinceEpoch ~/ 1000,
          });
          filesFound++;
          if (pendingUpserts.length >= batchSize || DateTime.now().difference(lastFlushAt) >= flushInterval) {
            await flushIncBatch();
          }
        }
      }

      if (checkCancelled()) return await finishCancelled(pendingUpserts, pendingRemoved);

      while (pendingUpserts.isNotEmpty || pendingRemoved.isNotEmpty) {
        await flushIncBatch(includeRemoved: pendingUpserts.isEmpty);
      }

      await api.postJson(
        '/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/complete',
        body: {
          'complete': true,
          if (latestWatermark > 0) 'new_watermark': latestWatermark,
        },
      );

      _activeTasks.remove(key);
      _cancelledTasks.remove(key);
      final done = snapshotProgress(completed: true, cancelling: false);
      publish(done);
      onScanFinished?.call(done);
      return done;
    } catch (e) {
      if (sessionId.isNotEmpty) {
        try {
          await api.postJson(
            '/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/complete',
            body: {'complete': false},
          );
        } catch (_) {}
      }
      final msg = e is CloudApiException ? e.message : '$e';
      _errorByKey[key] = msg;
      final prev = _progressByKey[key];
      _activeTasks.remove(key);
      _cancelledTasks.remove(key);
      if (prev != null && !prev.completed && !prev.cancelled) {
        _progressByKey[key] = prev.copyWith(
          cancelling: false,
          error: msg,
          updatedAtMs: DateTime.now().millisecondsSinceEpoch,
        );
      }
      _notify();
      rethrow;
    } finally {
      final changed = _activeTasks.remove(key);
      final cancelledChanged = _cancelledTasks.remove(key);
      if (changed || cancelledChanged) {
        _notify();
      }
    }
  }

  Future<Map<String, dynamic>> _postBatchWithRetry(String sessionId, Map<String, dynamic> body) async {
    var attempt = 0;
    while (true) {
      try {
        return await api.postJson(
          '/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/batches',
          gzipBody: true,
          body: body,
        );
      } on CloudApiException catch (e) {
        if (e.statusCode == 429 && attempt < 2) {
          attempt++;
          await Future<void>.delayed(const Duration(seconds: 2));
          continue;
        }
        rethrow;
      }
    }
  }

  Future<String?> _resolveQuarkFolderPath(
    String folderId,
    String rootFolderId,
    Future<List<({String id, String name})>> Function(String id) ancestryFn,
  ) async {
    final ancestry = await ancestryFn(folderId);
    final rootIndex = ancestry.indexWhere((folder) => folder.id == rootFolderId);
    if (rootIndex == -1 && rootFolderId != QuarkStorageDriver.defaultRootFolderId) return null;
    var path = StoragePath.root;
    for (final folder in ancestry.skip(rootIndex + 1)) {
      path = StoragePath.join(path, folder.name);
    }
    return StoragePath.normalize(path);
  }

  bool _isPathInFolderScopes(String normPath, List<({String path, List<String> excludes})> scopes) {
    for (final scope in scopes) {
      final scopeNorm = StoragePath.normalize(scope.path);
      final inScope = scopeNorm == StoragePath.root || normPath == scopeNorm || normPath.startsWith('$scopeNorm/');
      if (inScope && !_isExcluded(normPath, scope.excludes)) {
        return true;
      }
    }
    return false;
  }

  bool _isExcluded(String path, List<String> excludes) {
    for (final ex in excludes) {
      final trimmed = ex.trim();
      if (trimmed.isEmpty) continue;
      final norm = StoragePath.normalize(trimmed);
      if (path == norm || (norm != StoragePath.root && path.startsWith('$norm/'))) return true;
    }
    return false;
  }

  ({String contentType, int maxBytes})? _classifySidecar(StorageEntry entry) {
    final lower = entry.name.toLowerCase();
    if (lower.endsWith('.nfo')) {
      return (contentType: 'application/xml', maxBytes: maxNfoBytes);
    }
    if (lower == 'poster.jpg' ||
        lower == 'poster.png' ||
        lower == 'fanart.jpg' ||
        lower == 'backdrop.jpg' ||
        lower == 'folder.jpg') {
      final ct = lower.endsWith('.png') ? 'image/png' : 'image/jpeg';
      return (contentType: ct, maxBytes: maxArtworkBytes);
    }
    return null;
  }

  Future<Uint8List?> _readSmallFile(StorageDriver driver, StorageEntry entry, int maxBytes) async {
    try {
      final builder = BytesBuilder(copy: false);
      await for (final chunk in driver.openRead(entry, start: 0, end: maxBytes)) {
        builder.add(chunk);
        if (builder.length > maxBytes) return null;
      }
      final bytes = builder.takeBytes();
      return bytes.isEmpty ? null : bytes;
    } catch (_) {
      return null;
    }
  }

  Future<void> _uploadSidecarBytes(String sha256Hex, Uint8List bytes, String contentType) async {
    try {
      final exists = await api.headExists('/api/v1/sidecars/${Uri.encodeComponent(sha256Hex)}');
      if (exists) return;
      await api.putRawBytes(
        '/api/v1/sidecars/${Uri.encodeComponent(sha256Hex)}',
        bytes: bytes,
        contentType: contentType,
      );
    } catch (_) {
      // Sidecar upload failure is non-fatal; server can fall back to filename parsing.
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _activeTasks.clear();
    _cancelledTasks.clear();
    _progressByKey.clear();
    _errorByKey.clear();
    super.dispose();
  }
}
