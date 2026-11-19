import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';

import '../../database/app_database.dart';
import '../library_watch_state_store.dart';

/// User choice when signing into a sync server account for the first time while
/// local workspace data exists on this device.
enum LocalMergePolicy { mergeLocal, accountOnly }

/// Manages archive isolation between the unauthenticated `'local'` workspace
/// and each authenticated `'acct:<normalizedUrl>:<userId>'` workspace while
/// keeping host-global connections, profiles, downloads, and LAN remote trust
/// untouched.
class LibraryWorkspaceStore {
  LibraryWorkspaceStore(this.db);

  final AppDatabase db;

  static const String localWorkspaceKey = 'local';

  static String accountWorkspaceKey(String serverUrl, String userId) {
    final normalized = serverUrl.trim().replaceAll(RegExp(r'/+$'), '').toLowerCase();
    return 'acct:$normalized:$userId';
  }

  /// Tables isolated per workspace in parent-before-child insertion order.
  static const List<String> _workspaceTables = [
    'mounts',
    'library_items',
    'library_files',
    'library_user_states',
    'work_watch_states',
    'library_work_bindings',
    'library_genres',
    'library_item_genres',
    'library_people',
    'library_credits',
    'library_lists',
    'library_list_items',
    'library_scan_states',
    'library_settings',
    'sync_outbox',
    'sync_journal',
  ];

  /// Device-global `sync_metadata` keys that survive workspace switching (device
  /// identity, onboarding flag, remote-control LAN trust/keys, active key, mode,
  /// and active cloud session credentials).
  static const Set<String> _preservedMetaKeys = {
    'device_id',
    'sync_device_name',
    'sync_onboarding_done',
    'sync_lan_priv_key',
    'sync_lan_pub_key',
    'sync_lan_trusted_peers',
    'sync_lan_prompted_peers',
    'sync_active_workspace_key',
    'sync_mode',
    'sync_server_url',
    'sync_server_kind',
    'sync_last_self_hosted_url',
    'sync_user_id',
    'sync_username',
    'sync_access_token',
    'sync_master_key',
  };

  static const String _localProxySettingKey = 'scraper.proxy';

  Future<bool> hasLocalSyncableContent() async {
    const probes = [
      "SELECT COUNT(*) AS c FROM mounts WHERE kind != 'local'",
      "SELECT COUNT(*) AS c FROM library_files lf JOIN mounts m ON m.id = lf.mount_id WHERE m.kind != 'local' AND lf.match_state != 'ignored'",
      "SELECT COUNT(*) AS c FROM work_watch_states WHERE source = 'local-library'",
      'SELECT COUNT(*) AS c FROM library_lists',
      "SELECT COUNT(*) AS c FROM library_settings WHERE key LIKE 'work-skip:%local-library%'",
    ];
    for (final sql in probes) {
      final row = await db.customSelect(sql).getSingleOrNull();
      if ((row?.read<int>('c') ?? 0) > 0) return true;
    }
    return false;
  }

  Future<bool> hasWorkspaceArchive(String key) async {
    final row = await db
        .customSelect(
          'SELECT 1 FROM sync_workspace_archives WHERE workspace_key = ? LIMIT 1',
          variables: [Variable<String>(key)],
        )
        .getSingleOrNull();
    return row != null;
  }

  Future<void> saveCurrentWorkspace(String key) async {
    final snapshot = await _captureSnapshot();
    final encoded = 'gz:${base64Encode(gzip.encode(utf8.encode(jsonEncode(snapshot))))}';
    final nowMs = DateTime.now().millisecondsSinceEpoch;
    await db.customStatement(
      'INSERT OR REPLACE INTO sync_workspace_archives (workspace_key, snapshot_json, updated_at) VALUES (?, ?, ?)',
      [key, encoded, nowMs],
    );
  }

  Future<void> switchToWorkspace({
    required String fromKey,
    required String toKey,
    LocalMergePolicy? firstBindPolicy,
  }) async {
    if (fromKey == toKey) {
      await _setActiveWorkspaceKey(toKey);
      return;
    }

    final targetArchive = await _loadArchive(toKey);
    final isFirstLocalBindWithMerge =
        targetArchive == null &&
        fromKey == localWorkspaceKey &&
        toKey != localWorkspaceKey &&
        firstBindPolicy == LocalMergePolicy.mergeLocal;

    if (isFirstLocalBindWithMerge) {
      // Back up the pre-bind local workspace as an archive before promoting it
      // into the new account workspace so a later sign-out can still restore
      // or cleanly separate local state, while keeping all current mounts,
      // items, lists, and progress ready for the initial merge push/pull.
      await saveCurrentWorkspace(localWorkspaceKey);
      await db.transaction(() async {
        await db.customStatement('DELETE FROM sync_outbox');
        await db.customStatement(
          "DELETE FROM sync_metadata WHERE key IN ('last_pull_seq', 'sync_cloud_pushed_seq', 'sync_remapped_sources', 'sync_initial_completed')",
        );
        await _setActiveWorkspaceKey(toKey);
      });
      return;
    }

    await saveCurrentWorkspace(fromKey);
    final currentProxy = await _readLocalProxy();

    await db.transaction(() async {
      await db.customStatement('PRAGMA defer_foreign_keys = ON');
      await _clearWorkspaceTables();
      if (targetArchive != null) {
        await _restoreSnapshot(targetArchive, fallbackProxy: currentProxy);
      } else if (currentProxy != null && currentProxy.isNotEmpty) {
        await db.customStatement('INSERT OR REPLACE INTO library_settings (key, value) VALUES (?, ?)', [
          _localProxySettingKey,
          currentProxy,
        ]);
      }
      await _setActiveWorkspaceKey(toKey);
    });

    await LibraryWatchStateStore(db).restoreAll();
  }

  Future<String?> _readLocalProxy() async {
    final row = await db
        .customSelect(
          'SELECT value FROM library_settings WHERE key = ? LIMIT 1',
          variables: [const Variable<String>(_localProxySettingKey)],
        )
        .getSingleOrNull();
    return row?.readNullable<String>('value');
  }

  Future<void> _setActiveWorkspaceKey(String key) async {
    await db.customStatement('INSERT OR REPLACE INTO sync_metadata (key, value) VALUES (?, ?)', [
      'sync_active_workspace_key',
      key,
    ]);
  }

  Future<Map<String, Object?>> _captureSnapshot() async {
    final tables = <String, Object?>{};
    for (final table in _workspaceTables) {
      final sql = table == 'sync_journal' ? 'SELECT * FROM sync_journal WHERE is_deleted = 0' : 'SELECT * FROM $table';
      final rows = await db.customSelect(sql).get();
      tables[table] = [
        for (final row in rows) {for (final entry in row.data.entries) entry.key: _encodeValue(entry.value)},
      ];
    }
    final metaRows = await db.customSelect('SELECT key, value FROM sync_metadata').get();
    final meta = <String, String>{};
    for (final row in metaRows) {
      final k = row.read<String>('key');
      if (_preservedMetaKeys.contains(k)) continue;
      meta[k] = row.read<String>('value');
    }
    return {'version': 1, 'tables': tables, 'meta': meta};
  }

  Future<Map<String, dynamic>?> _loadArchive(String key) async {
    final row = await db
        .customSelect(
          'SELECT snapshot_json FROM sync_workspace_archives WHERE workspace_key = ? LIMIT 1',
          variables: [Variable<String>(key)],
        )
        .getSingleOrNull();
    final raw = row?.readNullable<String>('snapshot_json');
    if (raw == null || raw.isEmpty) return null;
    try {
      final jsonText = raw.startsWith('gz:') ? utf8.decode(gzip.decode(base64Decode(raw.substring(3)))) : raw;
      final decoded = jsonDecode(jsonText);
      return decoded is Map<String, dynamic> ? decoded : null;
    } on FormatException {
      return null;
    } on Object {
      return null;
    }
  }

  Future<void> _clearWorkspaceTables() async {
    for (final table in _workspaceTables.reversed) {
      await db.customStatement('DELETE FROM $table');
    }
    final placeholders = List.filled(_preservedMetaKeys.length, '?').join(', ');
    await db.customStatement(
      'DELETE FROM sync_metadata WHERE key NOT IN ($placeholders)',
      _preservedMetaKeys.toList(growable: false),
    );
  }

  Future<void> _restoreSnapshot(Map<String, dynamic> snapshot, {String? fallbackProxy}) async {
    final rawTables = snapshot['tables'];
    if (rawTables is Map) {
      for (final table in _workspaceTables) {
        final rawRows = rawTables[table];
        if (rawRows is! List || rawRows.isEmpty) continue;
        final validColumns = await _tableColumnNames(table);
        if (validColumns.isEmpty) continue;

        for (final rawRow in rawRows) {
          if (rawRow is! Map) continue;
          final cols = <String>[];
          final args = <Object?>[];
          for (final entry in rawRow.entries) {
            final colName = '${entry.key}';
            if (!validColumns.contains(colName)) continue;
            cols.add(colName);
            args.add(_decodeValue(entry.value));
          }
          if (cols.isEmpty) continue;
          final colList = cols.join(', ');
          final placeholders = List.filled(cols.length, '?').join(', ');
          await db.customStatement('INSERT OR REPLACE INTO $table ($colList) VALUES ($placeholders)', args);
        }
      }
    }

    if (fallbackProxy != null && fallbackProxy.isNotEmpty) {
      final targetProxy = await _readLocalProxy();
      if (targetProxy == null || targetProxy.isEmpty) {
        await db.customStatement('INSERT OR REPLACE INTO library_settings (key, value) VALUES (?, ?)', [
          _localProxySettingKey,
          fallbackProxy,
        ]);
      }
    }

    final rawMeta = snapshot['meta'];
    if (rawMeta is Map) {
      for (final entry in rawMeta.entries) {
        final key = '${entry.key}';
        if (_preservedMetaKeys.contains(key)) continue;
        final val = entry.value?.toString();
        if (val == null) continue;
        await db.customStatement('INSERT OR REPLACE INTO sync_metadata (key, value) VALUES (?, ?)', [key, val]);
      }
    }
  }

  Future<Set<String>> _tableColumnNames(String table) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return {for (final row in rows) row.read<String>('name')};
  }

  static Object? _encodeValue(Object? value) {
    if (value is Uint8List) {
      return {'__plezy_b64': base64Encode(value)};
    }
    return value;
  }

  static Object? _decodeValue(Object? value) {
    if (value is Map && value['__plezy_b64'] is String) {
      return base64Decode(value['__plezy_b64'] as String);
    }
    return value;
  }
}
