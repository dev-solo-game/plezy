import 'dart:async';
import 'dart:collection';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

import '../storage/storage_driver.dart';
import 'cloud_api_client.dart';

class CloudScanProgress {
  const CloudScanProgress({
    required this.sourceId,
    required this.sessionId,
    required this.directoriesVisited,
    required this.filesReported,
    required this.batchesSent,
    this.completed = false,
    this.error,
  });

  final String sourceId;
  final String sessionId;
  final int directoriesVisited;
  final int filesReported;
  final int batchesSent;
  final bool completed;
  final String? error;
}

/// Client-side scanner & idempotent batch ingest runner for `media_library` (S3).
///
/// Walks configured folders using a local [StorageDriver] (Quark / WebDAV),
/// uploads batches with gzip compression, uploads missing sidecar NFO/artwork
/// bytes when requested by the server, and finishes the session cleanly.
class CloudScanSessionRunner {
  CloudScanSessionRunner({
    required this.api,
    this.batchSize = 400,
    this.maxNfoBytes = 64 * 1024,
    this.maxArtworkBytes = 300 * 1024,
  });

  final CloudApiClient api;
  final int batchSize;
  final int maxNfoBytes;
  final int maxArtworkBytes;

  final Set<String> _activeSources = <String>{};

  bool isScanning(String sourceId) => _activeSources.contains(sourceId);

  /// Runs a full or folder scan session for [sourceId] using [driver].
  ///
  /// Throws [StateError] if this device is already scanning [sourceId] (local
  /// deduplication; server remains lock-free per S3 design).
  Future<CloudScanProgress> runScan({
    required String sourceId,
    required StorageDriver driver,
    String scanType = 'full',
    String? folderId,
    void Function(CloudScanProgress progress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    if (!_activeSources.add(sourceId)) {
      throw StateError('Scan already running locally for source $sourceId');
    }

    String sessionId = '';
    var dirsVisited = 0;
    var filesReported = 0;
    var batchesSent = 0;

    try {
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
      final sidecarEntryByHash = <String, ({StorageEntry entry, String contentType, int maxBytes})>{};
      var batchNo = 0;

      Future<void> flushBatch() async {
        if (pendingUpserts.isEmpty) return;
        batchNo++;
        final chunk = List<Map<String, dynamic>>.from(pendingUpserts);
        pendingUpserts.clear();

        final resp = await api.postJson(
          '/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/batches',
          gzipBody: true,
          body: {
            'batch_no': batchNo,
            'upserts': chunk,
          },
        );
        batchesSent++;
        filesReported += chunk.length;

        final receipt = resp['receipt'];
        if (receipt is Map) {
          final missing = receipt['missing_sidecars'];
          if (missing is List && missing.isNotEmpty) {
            for (final rawHash in missing) {
              final hash = '$rawHash';
              final ref = sidecarEntryByHash[hash];
              if (ref == null) continue;
              await _uploadSidecarIfReadable(driver, hash, ref.entry, ref.contentType, ref.maxBytes);
            }
          }
        }

        onProgress?.call(
          CloudScanProgress(
            sourceId: sourceId,
            sessionId: sessionId,
            directoriesVisited: dirsVisited,
            filesReported: filesReported,
            batchesSent: batchesSent,
          ),
        );
      }

      for (final scope in folderScopes) {
        final queue = Queue<({String path, StorageEntry? entry})>()..add((path: scope.path, entry: null));
        final visited = <String>{};

        while (queue.isNotEmpty) {
          if (isCancelled?.call() == true) {
            await api.postJson('/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/cancel');
            return CloudScanProgress(
              sourceId: sourceId,
              sessionId: sessionId,
              directoriesVisited: dirsVisited,
              filesReported: filesReported,
              batchesSent: batchesSent,
              completed: false,
            );
          }

          final current = queue.removeFirst();
          if (!visited.add(current.path)) continue;
          if (_isExcluded(current.path, scope.excludes)) continue;

          final children = await driver.list(current.path, parent: current.entry);
          dirsVisited++;

          for (final child in children) {
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

            final sidecarSpec = _classifySidecar(child);
            if (sidecarSpec != null && (child.size == null || child.size! <= sidecarSpec.maxBytes)) {
              final bytes = await _readSmallFile(driver, child, sidecarSpec.maxBytes);
              if (bytes != null) {
                final hash = crypto.sha256.convert(bytes).toString();
                item['sidecar_hash'] = hash;
                sidecarEntryByHash[hash] = (
                  entry: child,
                  contentType: sidecarSpec.contentType,
                  maxBytes: sidecarSpec.maxBytes,
                );
              }
            }

            pendingUpserts.add(item);
            if (pendingUpserts.length >= batchSize) {
              await flushBatch();
            }
          }
        }
      }

      await flushBatch();

      await api.postJson(
        '/api/v1/scan-sessions/${Uri.encodeComponent(sessionId)}/complete',
        body: {'complete': true},
      );

      final done = CloudScanProgress(
        sourceId: sourceId,
        sessionId: sessionId,
        directoriesVisited: dirsVisited,
        filesReported: filesReported,
        batchesSent: batchesSent,
        completed: true,
      );
      onProgress?.call(done);
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
      rethrow;
    } finally {
      _activeSources.remove(sourceId);
    }
  }

  bool _isExcluded(String path, List<String> excludes) {
    for (final ex in excludes) {
      final norm = ex.trim();
      if (norm.isEmpty) continue;
      if (path == norm || path.startsWith('$norm/')) return true;
    }
    return false;
  }

  ({String contentType, int maxBytes})? _classifySidecar(StorageEntry entry) {
    final lower = entry.name.toLowerCase();
    if (lower.endsWith('.nfo')) {
      return (contentType: 'application/xml', maxBytes: maxNfoBytes);
    }
    if (lower == 'poster.jpg' ||
        lower == 'poster.jpeg' ||
        lower == 'fanart.jpg' ||
        lower == 'folder.jpg' ||
        lower.endsWith('-poster.jpg')) {
      return (contentType: 'image/jpeg', maxBytes: maxArtworkBytes);
    }
    if (lower == 'poster.png' || lower == 'fanart.png' || lower == 'logo.png') {
      return (contentType: 'image/png', maxBytes: maxArtworkBytes);
    }
    return null;
  }

  Future<Uint8List?> _readSmallFile(StorageDriver driver, StorageEntry entry, int maxBytes) async {
    try {
      final chunks = <int>[];
      await for (final chunk in driver.openRead(entry, start: 0, end: maxBytes - 1)) {
        chunks.addAll(chunk);
        if (chunks.length > maxBytes) return null;
      }
      if (chunks.isEmpty) return null;
      return Uint8List.fromList(chunks);
    } catch (_) {
      return null;
    }
  }

  Future<void> _uploadSidecarIfReadable(
    StorageDriver driver,
    String sha256Hex,
    StorageEntry entry,
    String contentType,
    int maxBytes,
  ) async {
    final bytes = await _readSmallFile(driver, entry, maxBytes);
    if (bytes == null) return;
    await api.putRawBytes(
      '/api/v1/sidecars/${Uri.encodeComponent(sha256Hex)}',
      bytes: bytes,
      contentType: contentType,
    );
  }
}
