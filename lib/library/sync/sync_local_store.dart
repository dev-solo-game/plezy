import 'dart:convert';

import 'package:clock/clock.dart';
import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../database/app_database.dart';
import '../../media/work_identity.dart';
import '../../services/work_skip_settings_store.dart';
import '../library_watch_state_store.dart';
import 'deterministic_keys.dart';

/// Persists local sync metadata, calibrated timestamps, and the pending
/// [SyncOutbox] queue used by incremental synchronization.
class SyncLocalStore {
  SyncLocalStore(this.db);

  final AppDatabase db;

  static const String _kLastPullSeq = 'last_pull_seq';
  static const String _kServerTimeOffsetMs = 'server_time_offset_ms';
  static const String _kDeviceId = 'device_id';

  static const String typeSource = 'source';
  static const String typeWork = 'work';
  static const String typeFile = 'file';
  static const String typeWorkPref = 'work_pref';
  static const String typeWatchProgress = 'watch_progress';

  Future<String?> _getMeta(String key) async {
    final row = await (db.select(db.syncMetadata)..where((t) => t.key.equals(key))).getSingleOrNull();
    return row?.value;
  }

  Future<void> _putMeta(String key, String value) async {
    await db.into(db.syncMetadata).insertOnConflictUpdate(SyncMetadataCompanion.insert(key: key, value: value));
  }

  Future<int> getLastPullSeq() async => int.tryParse(await _getMeta(_kLastPullSeq) ?? '') ?? 0;

  Future<void> saveLastPullSeq(int seq) => _putMeta(_kLastPullSeq, '$seq');

  Future<int> getServerTimeOffsetMs() async => int.tryParse(await _getMeta(_kServerTimeOffsetMs) ?? '') ?? 0;

  Future<void> saveServerTimeOffsetMs(int offsetMs) => _putMeta(_kServerTimeOffsetMs, '$offsetMs');

  Future<String> getOrCreateDeviceId() async {
    final existing = await _getMeta(_kDeviceId);
    if (existing != null && existing.isNotEmpty) return existing;
    final generated = const Uuid().v4();
    await _putMeta(_kDeviceId, generated);
    return generated;
  }

  Future<int> calibratedNowMs() async => clock.now().millisecondsSinceEpoch + await getServerTimeOffsetMs();

  /// Inserts or collapses an outbox mutation for `(entityType, entityKey)`,
  /// assigning a fresh [opId] so older in-flight pushes cannot remove newer edits.
  Future<void> enqueue({
    required String entityType,
    required String entityKey,
    required Map<String, Object?> payload,
    int? updatedAt,
  }) async {
    final clientUpdatedAt = updatedAt ?? await calibratedNowMs();
    final createdAt = clock.now().millisecondsSinceEpoch;
    final opId = const Uuid().v4();
    await db
        .into(db.syncOutbox)
        .insertOnConflictUpdate(
          SyncOutboxCompanion.insert(
            entityType: entityType,
            entityKey: entityKey,
            opId: opId,
            payloadJson: jsonEncode(payload),
            clientUpdatedAt: clientUpdatedAt,
            createdAt: createdAt,
          ),
        );
  }

  /// Queues watch progress changes for a movie, episode, or all episodes of a
  /// show/season when marked watched/unwatched.
  Future<void> enqueueWatchProgressForItemId(int itemId, {int? updatedAt}) async {
    final item = await (db.select(db.libraryItems)..where((t) => t.id.equals(itemId))).getSingleOrNull();
    if (item == null) return;

    if (item.kind == 'show' || item.kind == 'season') {
      final items = db.libraryItems;
      final episodes = await (db.select(items)
            ..where(
              (t) =>
                  t.kind.equals('episode') &
                  (item.kind == 'show' ? t.showId.equals(itemId) : t.parentId.equals(itemId)),
            ))
          .get();
      for (final episode in episodes) {
        await _enqueueLeafProgress(episode.id, updatedAt: updatedAt);
      }
      return;
    }

    if (item.kind == 'movie' || item.kind == 'episode') {
      await _enqueueLeafProgress(item.id, updatedAt: updatedAt);
    }
  }

  Future<void> _enqueueLeafProgress(int itemId, {int? updatedAt}) async {
    final binding = await (db.select(db.libraryWorkBindings)..where((t) => t.itemId.equals(itemId))).getSingleOrNull();
    if (binding == null) return;
    final state = await (db.select(
      db.workWatchStates,
    )..where((t) => t.stateKey.equals(binding.stateKey))).getSingleOrNull();
    if (state == null || state.source != WorkIdentity.localSource) return;

    final workKey = '${state.provider}:${state.kind}:${state.externalId}';
    final progressKey = DeterministicKeys.generateProgressKey(
      workKey: workKey,
      kind: state.kind,
      seasonNum: state.seasonNumber,
      episodeNum: state.episodeNumber,
    );
    final effectiveUpdatedAt = updatedAt ?? await calibratedNowMs();
    await enqueue(
      entityType: typeWatchProgress,
      entityKey: progressKey,
      updatedAt: effectiveUpdatedAt,
      payload: {
        'progress_key': progressKey,
        'work_key': workKey,
        'season_num': state.seasonNumber,
        'episode_num': state.episodeNumber,
        'position_ms': state.positionMs,
        'duration_ms': state.durationMs ?? 0,
        'watched': state.watched,
        'play_count': state.playCount,
        'last_played_at': state.lastPlayedAt,
        'client_updated_at': effectiveUpdatedAt,
      },
    );
  }

  Future<void> enqueueWorkPrefsForItemId(int itemId, {int? updatedAt}) async {
    final work = await LibraryWatchStateStore(db).resolveWork(itemId);
    if (work == null || work.source != WorkIdentity.localSource) return;
    await enqueueWorkPrefsForIdentity(work, updatedAt: updatedAt);
  }

  /// Queues whole-work preferences (intro/credits skip + favorite/hidden flags)
  /// for a scraped local movie or show.
  Future<void> enqueueWorkPrefsForIdentity(WorkIdentity work, {int? updatedAt}) async {
    if (work.source != WorkIdentity.localSource) return;
    final workKey = '${work.provider}:${work.kind}:${work.externalId}';
    final skip = await WorkSkipSettingsStore(db).read(work);
    final wholeState = await LibraryWatchStateStore(db).read(work.stateKey());
    final effectiveUpdatedAt = updatedAt ?? await calibratedNowMs();
    await enqueue(
      entityType: typeWorkPref,
      entityKey: workKey,
      updatedAt: effectiveUpdatedAt,
      payload: {
        'work_key': workKey,
        'intro_enabled': skip.introEnabled,
        'intro_start_ms': skip.introStartMs,
        'intro_end_ms': skip.introEndMs,
        'credits_enabled': skip.creditsEnabled,
        'credits_from_end_ms': skip.creditsDurationMs,
        'keep_easter_egg_ms': skip.creditsResumeBeforeEndMs,
        'is_favorite': wholeState?.favorite ?? false,
        'hidden_from_continue': wholeState?.hiddenFromContinue ?? false,
        'client_updated_at': effectiveUpdatedAt,
      },
    );
  }

  Future<List<SyncOutboxRow>> readPendingOutbox({int limit = 200}) {
    return (db.select(db.syncOutbox)
          ..orderBy([(t) => OrderingTerm.asc(t.clientUpdatedAt)])
          ..limit(limit))
        .get();
  }

  Future<void> deleteAcceptedOutbox(Iterable<String> acceptedOpIds) async {
    final ids = acceptedOpIds.where((id) => id.isNotEmpty).toList();
    if (ids.isEmpty) return;
    await (db.delete(db.syncOutbox)..where((t) => t.opId.isIn(ids))).go();
  }
}
