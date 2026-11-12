import 'dart:async';
import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../database/app_database.dart';
import '../services/credential_vault.dart';
import '../utils/app_logger.dart';
import 'storage_mount.dart';

/// CRUD over the persisted [Mounts] table. Secrets are encrypted with
/// [CredentialVault] before they reach the database and decrypted here.
class MountRegistry {
  MountRegistry(this._db);

  final AppDatabase _db;

  static String newId() => const Uuid().v4();

  Stream<List<StorageMount>> watch() {
    return (_db.select(_db.mounts)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).watch().asyncMap(_decodeAll);
  }

  Future<List<StorageMount>> list() async {
    final rows = await (_db.select(_db.mounts)..orderBy([(t) => OrderingTerm.asc(t.createdAt)])).get();
    return _decodeAll(rows);
  }

  Future<StorageMount?> get(String id) async {
    final row = await (_db.select(_db.mounts)..where((t) => t.id.equals(id))).getSingleOrNull();
    return row == null ? null : _decode(row);
  }

  /// Inserts or replaces [mount]. An existing row keeps its creation time so
  /// editing a mount does not reorder the list.
  Future<void> upsert(StorageMount mount) async {
    final secrets = mount.secrets.isEmpty ? '' : await CredentialVault.protect(jsonEncode(mount.secrets));
    final existing = await (_db.select(_db.mounts)..where((t) => t.id.equals(mount.id))).getSingleOrNull();
    await _db
        .into(_db.mounts)
        .insertOnConflictUpdate(
          MountsCompanion.insert(
            id: mount.id,
            kind: mount.kind.id,
            displayName: mount.displayName,
            configJson: jsonEncode(mount.config),
            secrets: Value(secrets),
            createdAt: existing?.createdAt ?? (mount.createdAt ?? clock.now()).millisecondsSinceEpoch,
          ),
        );
  }

  /// Replaces one secret without touching the rest of the row — used when a
  /// driver reports rotated credentials (Quark refreshes its session cookie).
  Future<void> updateSecret(String id, String key, String value) => _db.transaction(() async {
    final mount = await get(id);
    if (mount == null) return;
    final secrets = await CredentialVault.protect(jsonEncode({...mount.secrets, key: value}));
    await (_db.update(_db.mounts)..where((t) => t.id.equals(id))).write(MountsCompanion(secrets: Value(secrets)));
  });

  Future<bool> updateQuarkDownloadOptions(String id, {required int connections, required int chunkMiB}) =>
      _db.transaction(() async {
        final mount = await get(id);
        if (mount == null || mount.kind != StorageKind.quark) return false;
        final config = jsonEncode({
          ...mount.config,
          MountKeys.quarkDownloadConnections: connections,
          MountKeys.quarkDownloadChunkMiB: chunkMiB,
        });
        await (_db.update(_db.mounts)..where((t) => t.id.equals(id))).write(MountsCompanion(configJson: Value(config)));
        return true;
      });

  Future<void> remove(String id) async {
    await (_db.delete(_db.mounts)..where((t) => t.id.equals(id))).go();
  }

  Future<List<StorageMount>> _decodeAll(List<MountRow> rows) async {
    return (await Future.wait(rows.map(_decode))).whereType<StorageMount>().toList();
  }

  /// Returns null for rows written by a newer build with a driver this one
  /// does not know. A mount whose secrets cannot be decrypted is still
  /// returned, without them, so the user can re-enter the credentials.
  Future<StorageMount?> _decode(MountRow row) async {
    final kind = StorageKind.fromId(row.kind);
    if (kind == null) {
      appLogger.w('Skipping mount ${row.id} with unknown kind "${row.kind}"');
      return null;
    }

    var config = const <String, Object?>{};
    try {
      final decoded = jsonDecode(row.configJson);
      if (decoded is Map<String, dynamic>) config = decoded;
    } on FormatException {
      appLogger.w('Mount ${row.id} has unreadable config; using defaults');
    }

    var secrets = const <String, String>{};
    if (row.secrets.isNotEmpty) {
      final clear = await CredentialVault.reveal(row.secrets);
      if (clear == null) {
        appLogger.w('Mount ${row.id} secrets could not be decrypted');
      } else {
        try {
          final decoded = jsonDecode(clear);
          if (decoded is Map) {
            secrets = {
              for (final entry in decoded.entries)
                if (entry.key is String && entry.value is String) entry.key as String: entry.value as String,
            };
          }
        } on FormatException {
          appLogger.w('Mount ${row.id} has unreadable secrets');
        }
      }
    }

    return StorageMount(
      id: row.id,
      kind: kind,
      displayName: row.displayName,
      config: config,
      secrets: secrets,
      createdAt: DateTime.fromMillisecondsSinceEpoch(row.createdAt),
    );
  }
}
