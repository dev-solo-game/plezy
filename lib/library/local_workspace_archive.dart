import 'dart:convert';
import 'dart:io';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';

import '../database/app_database.dart';
import 'library_watch_state_store.dart';

/// Snapshots and restores the offline local library workspace inside
/// `sync_workspace_archives` without touching device identity or paired LAN
/// keys in `sync_metadata`.
class LocalWorkspaceArchive {
  LocalWorkspaceArchive(this.db);

  final AppDatabase db;

  static const String localWorkspaceKey = 'local';
  static const String _gzPrefix = 'gz:';
  static const String _bytesMarker = '__plezy_b64';

  /// Ordered parent-before-child so a clean replay respects foreign keys.
  static const List<String> _captureTables = [
    'mounts',
    'library_settings',
    'library_scan_states',
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
  ];

  /// Reverse child-before-parent order for clean deletion.
  static const List<String> _deleteOrder = [
    'library_list_items',
    'library_lists',
    'library_credits',
    'library_people',
    'library_item_genres',
    'library_genres',
    'library_work_bindings',
    'work_watch_states',
    'library_user_states',
    'library_files',
    'library_items',
    'library_scan_states',
    'library_settings',
    'mounts',
  ];

  Future<bool> hasArchive([String workspaceKey = localWorkspaceKey]) async {
    final row = await db.customSelect(
      'SELECT 1 AS hit FROM sync_workspace_archives WHERE workspace_key = ? LIMIT 1',
      variables: [Variable.withString(workspaceKey)],
    ).getSingleOrNull();
    return row != null;
  }

  Future<bool> hasLocalLibraryData() async {
    for (final table in const ['mounts', 'library_items', 'library_lists', 'work_watch_states']) {
      final row = await db.customSelect('SELECT 1 AS hit FROM $table LIMIT 1').getSingleOrNull();
      if (row != null) return true;
    }
    return false;
  }

  Future<void> captureSnapshot([String workspaceKey = localWorkspaceKey]) async {
    final tables = <String, List<Map<String, dynamic>>>{};
    for (final table in _captureTables) {
      final rows = await db.customSelect('SELECT * FROM $table').get();
      tables[table] = [
        for (final row in rows)
          {
            for (final entry in row.data.entries) entry.key: _encodeValue(entry.value),
          },
      ];
    }

    final jsonStr = jsonEncode({
      'version': 1,
      'captured_at': clock.now().millisecondsSinceEpoch,
      'tables': tables,
    });
    final compressed = gzip.encode(utf8.encode(jsonStr));
    final encoded = '$_gzPrefix${base64Encode(compressed)}';

    await db.customInsert(
      'INSERT OR REPLACE INTO sync_workspace_archives (workspace_key, snapshot_json, updated_at) VALUES (?, ?, ?)',
      variables: [
        Variable.withString(workspaceKey),
        Variable.withString(encoded),
        Variable.withInt(clock.now().millisecondsSinceEpoch),
      ],
    );
  }

  Future<bool> restoreSnapshot([
    String workspaceKey = localWorkspaceKey,
    bool deleteArchiveAfterRestore = true,
  ]) async {
    final archRow = await db.customSelect(
      'SELECT snapshot_json FROM sync_workspace_archives WHERE workspace_key = ?',
      variables: [Variable.withString(workspaceKey)],
    ).getSingleOrNull();
    if (archRow == null) return false;

    final rawSnap = archRow.read<String>('snapshot_json');
    final decodedStr = rawSnap.startsWith(_gzPrefix)
        ? utf8.decode(gzip.decode(base64Decode(rawSnap.substring(_gzPrefix.length))))
        : rawSnap;
    final payload = jsonDecode(decodedStr);
    if (payload is! Map) return false;
    final tablesRaw = payload['tables'];
    if (tablesRaw is! Map) return false;

    await db.transaction(() async {
      await db.customStatement('PRAGMA defer_foreign_keys = ON');
      for (final table in _deleteOrder) {
        await db.customStatement('DELETE FROM $table');
      }

      for (final table in _captureTables) {
        final rawList = tablesRaw[table];
        if (rawList is! List || rawList.isEmpty) continue;

        final validColumns = await _tableColumns(table);
        if (validColumns.isEmpty) continue;

        for (final rawRow in rawList) {
          if (rawRow is! Map) continue;
          final cols = <String>[];
          final vars = <Variable<Object>>[];
          for (final entry in rawRow.entries) {
            final col = entry.key.toString();
            if (!validColumns.contains(col)) continue;
            cols.add(col);
            vars.add(_toVariable(_decodeValue(entry.value)));
          }
          if (cols.isEmpty) continue;
          final placeholders = List<String>.filled(cols.length, '?').join(', ');
          await db.customInsert(
            'INSERT OR REPLACE INTO $table (${cols.join(', ')}) VALUES ($placeholders)',
            variables: vars,
          );
        }
      }

      if (deleteArchiveAfterRestore) {
        await db.customStatement(
          'DELETE FROM sync_workspace_archives WHERE workspace_key = ?',
          [workspaceKey],
        );
      }
    });

    await LibraryWatchStateStore(db).restoreAll();
    return true;
  }

  Future<void> clearLocalLibraryTables() async {
    await db.transaction(() async {
      await db.customStatement('PRAGMA defer_foreign_keys = ON');
      for (final table in _deleteOrder) {
        await db.customStatement('DELETE FROM $table');
      }
    });
  }

  Future<void> deleteArchive([String workspaceKey = localWorkspaceKey]) async {
    await db.customStatement(
      'DELETE FROM sync_workspace_archives WHERE workspace_key = ?',
      [workspaceKey],
    );
  }

  Future<Set<String>> _tableColumns(String table) async {
    final info = await db.customSelect('PRAGMA table_info($table)').get();
    return {for (final row in info) row.read<String>('name')};
  }

  static Object? _encodeValue(Object? value) {
    if (value is Uint8List) {
      return {_bytesMarker: base64Encode(value)};
    }
    return value;
  }

  static Object? _decodeValue(Object? value) {
    if (value is Map && value.length == 1 && value[_bytesMarker] is String) {
      return Uint8List.fromList(base64Decode(value[_bytesMarker] as String));
    }
    return value;
  }

  static Variable<Object> _toVariable(Object? value) {
    if (value == null) return const Variable<Object>(null);
    if (value is int) return Variable.withInt(value);
    if (value is double) return Variable.withReal(value);
    if (value is bool) return Variable.withBool(value);
    if (value is Uint8List) return Variable.withBlob(value);
    return Variable.withString(value.toString());
  }
}
