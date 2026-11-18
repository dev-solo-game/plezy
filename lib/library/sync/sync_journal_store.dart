import 'dart:convert';
import 'dart:math' as math;

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../../storage/storage_path.dart';

/// Persistent local record in `sync_journal` tracking the latest canonical state,
/// monotonic `local_seq`, causal origin, and deletion tombstones for incremental
/// LAN P2P and cloud synchronization.
class SyncJournalEntry {
  const SyncJournalEntry({
    required this.entityType,
    required this.entityKey,
    this.sourceId,
    this.relativePath,
    this.workKey,
    required this.localSeq,
    required this.payloadHash,
    required this.payloadJson,
    required this.clientUpdatedAt,
    this.isDeleted = false,
    this.originDeviceId,
    this.originEpoch,
  });

  final String entityType;
  final String entityKey;
  final String? sourceId;
  final String? relativePath;
  final String? workKey;
  final int localSeq;
  final String payloadHash;
  final String payloadJson;
  final int clientUpdatedAt;
  final bool isDeleted;
  final String? originDeviceId;
  final String? originEpoch;

  Map<String, Object?> decodePayload() {
    final decoded = jsonDecode(payloadJson);
    if (decoded is! Map) return const {};
    return {for (final entry in decoded.entries) '${entry.key}': entry.value};
  }

  SyncJournalEntry copyWith({
    String? sourceId,
    String? relativePath,
    String? workKey,
    int? localSeq,
    String? payloadHash,
    String? payloadJson,
    int? clientUpdatedAt,
    bool? isDeleted,
    String? originDeviceId,
    String? originEpoch,
  }) => SyncJournalEntry(
    entityType: entityType,
    entityKey: entityKey,
    sourceId: sourceId ?? this.sourceId,
    relativePath: relativePath ?? this.relativePath,
    workKey: workKey ?? this.workKey,
    localSeq: localSeq ?? this.localSeq,
    payloadHash: payloadHash ?? this.payloadHash,
    payloadJson: payloadJson ?? this.payloadJson,
    clientUpdatedAt: clientUpdatedAt ?? this.clientUpdatedAt,
    isDeleted: isDeleted ?? this.isDeleted,
    originDeviceId: originDeviceId ?? this.originDeviceId,
    originEpoch: originEpoch ?? this.originEpoch,
  );
}

/// Manages the `sync_journal` SQLite table and canonical entity hashing.
class SyncJournalStore {
  SyncJournalStore(this.db);

  final AppDatabase db;

  static const int _sqlChunkSize = 400;
  static const int defaultTombstoneRetentionMs = 30 * 24 * 60 * 60 * 1000;

  static const Set<String> _volatileTopLevelKeys = {
    'client_updated_at',
    'server_seq',
    'encrypted_auth',
    'force_auth_override',
    'scan_finished_at',
    'explicit_unlock',
    'is_deleted',
    'scan_lease_owner',
    'scan_lease_until',
  };

  /// Computes a canonical SHA-256 fingerprint for [payload], ignoring volatile
  /// sync envelope fields and random encryption nonces while incorporating
  /// plaintext [rawSecrets] when hashing a `source`.
  static String computeEntityHash(
    String entityType,
    Map<String, Object?> payload, {
    Map<String, String>? rawSecrets,
  }) {
    if (payload['is_deleted'] == true) {
      final deletedCanonical = jsonEncode({'entity_type': entityType, 'is_deleted': true});
      return sha256.convert(utf8.encode(deletedCanonical)).toString();
    }

    final normalized = <String, Object?>{};
    final keys = payload.keys.toList()..sort();
    for (final key in keys) {
      if (_volatileTopLevelKeys.contains(key)) continue;
      final value = payload[key];
      if (value == null) continue;
      if (entityType == 'file' && key == 'file_created_at' && value is num && value == 0) continue;
      if (entityType == 'work_pref' && key == 'playback_speed' && value is num && value == 0) continue;
      if (entityType == 'work_pref' && key == 'danmaku_offset_ms' && value is num && value == 0) continue;
      var canonicalValue = _canonicalizeValue(value);
      if (entityType == 'work' && key == 'metadata_json' && canonicalValue is Map<String, Object?>) {
        canonicalValue = _normalizeWorkMetadataForHash(canonicalValue);
      } else if (entityType == 'file' && key == 'media_spec_json' && canonicalValue is Map<String, Object?>) {
        canonicalValue = {
          for (final entry in canonicalValue.entries)
            if (entry.key != 'ep_scraped_at') entry.key: entry.value,
        };
      }
      if (canonicalValue == null) continue;
      if (canonicalValue is Map && canonicalValue.isEmpty) continue;
      normalized[key] = canonicalValue;
    }

    if (entityType == 'source' && rawSecrets != null && rawSecrets.isNotEmpty) {
      final sortedSecretKeys = rawSecrets.keys.toList()..sort();
      normalized['secrets'] = {for (final k in sortedSecretKeys) k: rawSecrets[k]};
    }

    final encoded = jsonEncode({'entity_type': entityType, 'payload': normalized});
    return sha256.convert(utf8.encode(encoded)).toString();
  }

  /// Strips secret ciphertext and transient push flags before persisting JSON
  /// inside `sync_journal`.
  static String sanitizePayloadJsonForStorage(String entityType, Map<String, Object?> payload) {
    final copy = Map<String, Object?>.from(payload);
    if (entityType == 'source') {
      copy['encrypted_auth'] = '';
      copy.remove('force_auth_override');
    }
    copy.remove('server_seq');
    return jsonEncode(copy);
  }

  static Map<String, Object?> _normalizeWorkMetadataForHash(Map<String, Object?> meta) {
    final out = <String, Object?>{};
    for (final entry in meta.entries) {
      final key = entry.key;
      final val = entry.value;
      if (key == 'source_added_at') continue;
      if (key == 'locked' && val == false) continue;
      if ((key == 'genres' || key == 'credits') && val is List && val.isEmpty) continue;
      out[key] = val;
    }
    return out;
  }

  static Object? _canonicalizeValue(Object? value) {
    if (value == null) return null;
    if (value is num) {
      if (value is double && value.isFinite && value == value.truncateToDouble()) {
        return value.toInt();
      }
      return value;
    }
    if (value is Map) {
      final keys = [for (final k in value.keys) '$k']..sort();
      final out = <String, Object?>{};
      for (final key in keys) {
        final canonical = _canonicalizeValue(value[key]);
        if (canonical == null) continue;
        if (canonical is Map && canonical.isEmpty) continue;
        out[key] = canonical;
      }
      return out;
    }
    if (value is List) {
      return [for (final item in value) _canonicalizeValue(item)];
    }
    return value;
  }

  static String? extractSourceId(String entityType, Map<String, Object?> payload) {
    final v = payload['source_id'];
    if (v is String && v.isNotEmpty) return v;
    if (entityType == 'source') {
      final id = payload['source_id'];
      if (id is String && id.isNotEmpty) return id;
    }
    return null;
  }

  static String? extractRelativePath(Map<String, Object?> payload) {
    final v = payload['relative_path'];
    return v is String && v.isNotEmpty ? v : null;
  }

  static String? extractWorkKey(Map<String, Object?> payload) {
    final v = payload['work_key'];
    return v is String && v.isNotEmpty ? v : null;
  }

  Future<int> getMaxLocalSeq() async {
    final row = await db.customSelect('SELECT COALESCE(MAX(local_seq), 0) AS max_seq FROM sync_journal').getSingle();
    return row.read<int>('max_seq');
  }

  Future<bool> hasAnyEntries() async {
    final rows = await db.customSelect('SELECT 1 AS present FROM sync_journal LIMIT 1').get();
    return rows.isNotEmpty;
  }

  Future<SyncJournalEntry?> getEntry(String entityType, String entityKey) async {
    final rows = await db
        .customSelect(
          'SELECT entity_type, entity_key, source_id, relative_path, work_key, local_seq, '
          'payload_hash, payload_json, client_updated_at, is_deleted, origin_device_id, origin_epoch '
          'FROM sync_journal WHERE entity_type = ? AND entity_key = ? LIMIT 1',
          variables: [Variable.withString(entityType), Variable.withString(entityKey)],
        )
        .get();
    if (rows.isEmpty) return null;
    return _rowToEntry(rows.single);
  }

  Future<Map<String, SyncJournalEntry>> getEntriesForType(String entityType, Iterable<String> keys) async {
    final unique = [
      for (final k in {...keys})
        if (k.isNotEmpty) k,
    ];
    if (unique.isEmpty) return {};

    final result = <String, SyncJournalEntry>{};
    for (var i = 0; i < unique.length; i += _sqlChunkSize) {
      final slice = unique.sublist(i, math.min(i + _sqlChunkSize, unique.length));
      final placeholders = List.filled(slice.length, '?').join(', ');
      final rows = await db
          .customSelect(
            'SELECT entity_type, entity_key, source_id, relative_path, work_key, local_seq, '
            'payload_hash, payload_json, client_updated_at, is_deleted, origin_device_id, origin_epoch '
            'FROM sync_journal WHERE entity_type = ? AND entity_key IN ($placeholders)',
            variables: [Variable.withString(entityType), for (final k in slice) Variable.withString(k)],
          )
          .get();
      for (final row in rows) {
        final entry = _rowToEntry(row);
        result[entry.entityKey] = entry;
      }
    }
    return result;
  }

  Future<List<SyncJournalEntry>> getEntriesByType(String entityType, {bool onlyActive = false}) async {
    final whereClause = onlyActive ? 'entity_type = ? AND is_deleted = 0' : 'entity_type = ?';
    final rows = await db
        .customSelect(
          'SELECT entity_type, entity_key, source_id, relative_path, work_key, local_seq, '
          'payload_hash, payload_json, client_updated_at, is_deleted, origin_device_id, origin_epoch '
          'FROM sync_journal WHERE $whereClause',
          variables: [Variable.withString(entityType)],
        )
        .get();
    return [for (final row in rows) _rowToEntry(row)];
  }

  Future<List<SyncJournalEntry>> getActiveFilesForMount(
    String sourceId, {
    Set<String>? directoryPrefixes,
  }) async {
    if (directoryPrefixes == null || directoryPrefixes.isEmpty) {
      final rows = await db
          .customSelect(
            "SELECT entity_type, entity_key, source_id, relative_path, work_key, local_seq, "
            "payload_hash, payload_json, client_updated_at, is_deleted, origin_device_id, origin_epoch "
            "FROM sync_journal WHERE entity_type = 'file' AND source_id = ? AND is_deleted = 0",
            variables: [Variable.withString(sourceId)],
          )
          .get();
      return [for (final row in rows) _rowToEntry(row)];
    }

    final normalizedDirs = <String>{
      for (final raw in directoryPrefixes) StoragePath.normalize(raw),
    };
    if (normalizedDirs.contains('/')) {
      return getActiveFilesForMount(sourceId);
    }

    final seenKeys = <String>{};
    final out = <SyncJournalEntry>[];
    for (final dir in normalizedDirs) {
      final prefix = '$dir/%';
      final rows = await db
          .customSelect(
            "SELECT entity_type, entity_key, source_id, relative_path, work_key, local_seq, "
            "payload_hash, payload_json, client_updated_at, is_deleted, origin_device_id, origin_epoch "
            "FROM sync_journal WHERE entity_type = 'file' AND source_id = ? AND is_deleted = 0 "
            'AND relative_path LIKE ?',
            variables: [Variable.withString(sourceId), Variable.withString(prefix)],
          )
          .get();
      for (final row in rows) {
        final entry = _rowToEntry(row);
        if (seenKeys.add(entry.entityKey)) {
          out.add(entry);
        }
      }
    }
    return out;
  }

  Future<List<SyncJournalEntry>> getEntriesForSource(String sourceId) async {
    final rows = await db
        .customSelect(
          'SELECT entity_type, entity_key, source_id, relative_path, work_key, local_seq, '
          'payload_hash, payload_json, client_updated_at, is_deleted, origin_device_id, origin_epoch '
          'FROM sync_journal WHERE source_id = ? OR (entity_type = ? AND entity_key = ?)',
          variables: [
            Variable.withString(sourceId),
            Variable.withString('source'),
            Variable.withString(sourceId),
          ],
        )
        .get();
    return [for (final row in rows) _rowToEntry(row)];
  }

  Future<List<SyncJournalEntry>> findOrphanedActiveWorks({bool includeMatchedUnreferenced = false}) async {
    final condition = includeMatchedUnreferenced
        ? "(w.entity_key LIKE 'raw:%' OR ("
              "NOT EXISTS (SELECT 1 FROM sync_journal f WHERE f.entity_type = 'file' AND f.is_deleted = 0 AND f.work_key = w.entity_key) "
              'AND NOT EXISTS (SELECT 1 FROM library_items i WHERE i.work_key = w.entity_key)'
              '))'
        : "w.entity_key LIKE 'raw:%'";
    final rows = await db
        .customSelect(
          'SELECT w.entity_type, w.entity_key, w.source_id, w.relative_path, w.work_key, w.local_seq, '
          'w.payload_hash, w.payload_json, w.client_updated_at, w.is_deleted, w.origin_device_id, w.origin_epoch '
          'FROM sync_journal w '
          "WHERE w.entity_type = 'work' AND w.is_deleted = 0 AND $condition",
        )
        .get();
    return [for (final row in rows) _rowToEntry(row)];
  }

  Future<List<SyncJournalEntry>> findOrphanedActiveRawWorks() =>
      findOrphanedActiveWorks(includeMatchedUnreferenced: false);

  Future<void> upsertEntry(SyncJournalEntry entry) async {
    await db.customStatement(
      '''
      INSERT INTO sync_journal (
        entity_type, entity_key, source_id, relative_path, work_key,
        local_seq, payload_hash, payload_json, client_updated_at,
        is_deleted, origin_device_id, origin_epoch
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(entity_type, entity_key) DO UPDATE SET
        source_id = excluded.source_id,
        relative_path = excluded.relative_path,
        work_key = excluded.work_key,
        local_seq = excluded.local_seq,
        payload_hash = excluded.payload_hash,
        payload_json = excluded.payload_json,
        client_updated_at = excluded.client_updated_at,
        is_deleted = excluded.is_deleted,
        origin_device_id = excluded.origin_device_id,
        origin_epoch = excluded.origin_epoch
      ''',
      [
        entry.entityType,
        entry.entityKey,
        entry.sourceId,
        entry.relativePath,
        entry.workKey,
        entry.localSeq,
        entry.payloadHash,
        entry.payloadJson,
        entry.clientUpdatedAt,
        entry.isDeleted ? 1 : 0,
        entry.originDeviceId,
        entry.originEpoch,
      ],
    );
  }

  Future<void> upsertEntries(Iterable<SyncJournalEntry> entries) async {
    for (final entry in entries) {
      await upsertEntry(entry);
    }
  }

  Future<void> deleteEntry(String entityType, String entityKey) async {
    await db.customStatement(
      'DELETE FROM sync_journal WHERE entity_type = ? AND entity_key = ?',
      [entityType, entityKey],
    );
  }

  Future<List<SyncJournalEntry>> getPendingCloudEntries({required int afterSeq, int limit = 500}) async {
    final rows = await db
        .customSelect(
          "SELECT entity_type, entity_key, source_id, relative_path, work_key, local_seq, "
          "payload_hash, payload_json, client_updated_at, is_deleted, origin_device_id, origin_epoch "
          "FROM sync_journal "
          "WHERE local_seq > ? AND COALESCE(origin_device_id, '') != 'cloud' "
          'ORDER BY local_seq ASC LIMIT ?',
          variables: [Variable.withInt(afterSeq), Variable.withInt(limit)],
        )
        .get();
    return [for (final row in rows) _rowToEntry(row)];
  }

  /// Queries a paginated delta slice ordered strictly by `local_seq`.
  ///
  /// When [sinceSeq] > 0 and [skipOriginEpoch] is provided, entries originating
  /// from `(skipOriginDeviceId, skipOriginEpoch)` are skipped as echo while
  /// advancing `nextSeq`, avoiding loopback storms without preventing full
  /// recovery after a peer reinstall (`sinceSeq == 0` or a new epoch).
  Future<({List<SyncJournalEntry> entries, int nextSeq, bool hasMore, int maxSeq})> queryDelta({
    required int sinceSeq,
    int limit = 500,
    String? skipOriginDeviceId,
    String? skipOriginEpoch,
    bool skipEchoEvenFromZero = false,
  }) async {
    final effectiveLimit = limit <= 0 ? 500 : limit;
    final maxSeq = await getMaxLocalSeq();
    final canSkipEcho =
        (sinceSeq > 0 || skipEchoEvenFromZero) &&
        skipOriginDeviceId != null &&
        skipOriginDeviceId.isNotEmpty &&
        skipOriginEpoch != null &&
        skipOriginEpoch.isNotEmpty;

    final result = <SyncJournalEntry>[];
    var cursor = sinceSeq;
    final batchSize = math.max(effectiveLimit, 500);
    var lastConsumedSeq = sinceSeq;

    while (true) {
      final rows = await db
          .customSelect(
            'SELECT entity_type, entity_key, source_id, relative_path, work_key, local_seq, '
            'payload_hash, payload_json, client_updated_at, is_deleted, origin_device_id, origin_epoch '
            'FROM sync_journal WHERE local_seq > ? ORDER BY local_seq ASC LIMIT ?',
            variables: [Variable.withInt(cursor), Variable.withInt(batchSize + 1)],
          )
          .get();

      if (rows.isEmpty) {
        return (entries: result, nextSeq: math.max(lastConsumedSeq, maxSeq), hasMore: false, maxSeq: maxSeq);
      }

      final hasMoreInDb = rows.length > batchSize;
      final limitCount = hasMoreInDb ? batchSize : rows.length;
      for (var i = 0; i < limitCount; i++) {
        final entry = _rowToEntry(rows[i]);
        // Never revive old tombstones inside initial full rebuilds (`sinceSeq == 0`).
        if (sinceSeq == 0 && entry.isDeleted) {
          lastConsumedSeq = entry.localSeq;
          continue;
        }
        final isEcho =
            canSkipEcho && entry.originDeviceId == skipOriginDeviceId && entry.originEpoch == skipOriginEpoch;
        lastConsumedSeq = entry.localSeq;
        if (isEcho) continue;

        result.add(entry);
        if (result.length >= effectiveLimit) {
          final moreLeft = (i + 1 < limitCount) || hasMoreInDb;
          return (
            entries: result,
            nextSeq: moreLeft ? lastConsumedSeq : math.max(lastConsumedSeq, maxSeq),
            hasMore: moreLeft,
            maxSeq: maxSeq,
          );
        }
      }

      if (!hasMoreInDb) {
        return (entries: result, nextSeq: math.max(lastConsumedSeq, maxSeq), hasMore: false, maxSeq: maxSeq);
      }
      cursor = lastConsumedSeq;
    }
  }

  /// Removes deleted tombstones older than [retentionMs] and returns
  /// `(deletedCount, maxPurgedSeq)`.
  Future<({int deletedCount, int maxPurgedSeq})> pruneExpiredTombstones({
    required int nowMs,
    int retentionMs = defaultTombstoneRetentionMs,
  }) async {
    final cutoff = nowMs - retentionMs;
    final row = await db
        .customSelect(
          'SELECT COUNT(*) AS cnt, COALESCE(MAX(local_seq), 0) AS max_seq '
          'FROM sync_journal WHERE is_deleted = 1 AND client_updated_at <= ?',
          variables: [Variable.withInt(cutoff)],
        )
        .getSingle();
    final cnt = row.read<int>('cnt');
    final maxPurgedSeq = row.read<int>('max_seq');
    if (cnt > 0) {
      await db.customStatement(
        'DELETE FROM sync_journal WHERE is_deleted = 1 AND client_updated_at <= ?',
        [cutoff],
      );
    }
    return (deletedCount: cnt, maxPurgedSeq: maxPurgedSeq);
  }

  static SyncJournalEntry _rowToEntry(QueryRow row) => SyncJournalEntry(
    entityType: row.read<String>('entity_type'),
    entityKey: row.read<String>('entity_key'),
    sourceId: row.readNullable<String>('source_id'),
    relativePath: row.readNullable<String>('relative_path'),
    workKey: row.readNullable<String>('work_key'),
    localSeq: row.read<int>('local_seq'),
    payloadHash: row.read<String>('payload_hash'),
    payloadJson: row.read<String>('payload_json'),
    clientUpdatedAt: row.read<int>('client_updated_at'),
    isDeleted: row.read<int>('is_deleted') != 0,
    originDeviceId: row.readNullable<String>('origin_device_id'),
    originEpoch: row.readNullable<String>('origin_epoch'),
  );
}
