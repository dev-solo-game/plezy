import 'dart:async';
import 'dart:convert';

import 'cloud_api_client.dart';

class CloudSnapshotPage {
  const CloudSnapshotPage({
    required this.snapshotSeq,
    required this.items,
    required this.total,
    required this.page,
    required this.pageSize,
    required this.hasMore,
  });

  final int snapshotSeq;
  final List<Map<String, dynamic>> items;
  final int total;
  final int page;
  final int pageSize;
  final bool hasMore;

  factory CloudSnapshotPage.fromJson(Map<String, dynamic> json) => CloudSnapshotPage(
    snapshotSeq: (json['snapshot_seq'] as num?)?.toInt() ?? 0,
    items: [
      for (final i in (json['items'] as List? ?? const []))
        if (i is Map) Map<String, dynamic>.from(i),
    ],
    total: (json['total'] as num?)?.toInt() ?? 0,
    page: (json['page'] as num?)?.toInt() ?? 1,
    pageSize: (json['page_size'] as num?)?.toInt() ?? 50,
    hasMore: json['has_more'] == true,
  );
}

class CloudChangesPage {
  const CloudChangesPage({
    required this.resetRequired,
    required this.latestSeq,
    required this.minRetainedSeq,
    required this.nextSinceSeq,
    required this.hasMore,
    required this.changes,
  });

  final bool resetRequired;
  final int latestSeq;
  final int minRetainedSeq;
  final int nextSinceSeq;
  final bool hasMore;
  final List<Map<String, dynamic>> changes;

  factory CloudChangesPage.fromJson(Map<String, dynamic> json) => CloudChangesPage(
    resetRequired: json['reset_required'] == true,
    latestSeq: (json['latest_seq'] as num?)?.toInt() ?? 0,
    minRetainedSeq: (json['min_retained_seq'] as num?)?.toInt() ?? 0,
    nextSinceSeq: (json['next_since_seq'] as num?)?.toInt() ?? 0,
    hasMore: json['has_more'] == true,
    changes: [
      for (final c in (json['changes'] as List? ?? const []))
        if (c is Map) Map<String, dynamic>.from(c),
    ],
  );
}

class CloudSseEvent {
  const CloudSseEvent({required this.id, required this.type, required this.data});

  final String id;
  final String type;
  final Map<String, dynamic> data;
}

/// Downstream projection sync, SSE listener, and user-data client for
/// `media_library` S4/S5 endpoints.
class CloudProjectionSyncClient {
  CloudProjectionSyncClient(this.api);

  final CloudApiClient api;

  // ─── Snapshot, Incremental Changes & Item Detail ────────────────────────

  Future<CloudSnapshotPage> fetchSnapshot({
    String? kind,
    String? libraryType,
    String? sourceId,
    int? parentId,
    String? query,
    String? sort,
    int page = 1,
    int pageSize = 100,
  }) async {
    final resp = await api.getJson(
      '/api/v1/library/snapshot',
      query: {
        if (kind != null && kind.isNotEmpty) 'kind': kind,
        if (libraryType != null && libraryType.isNotEmpty) 'library_type': libraryType,
        if (sourceId != null && sourceId.isNotEmpty) 'source_id': sourceId,
        if (parentId != null && parentId > 0) 'parent_id': '$parentId',
        if (query != null && query.trim().isNotEmpty) 'q': query.trim(),
        if (sort != null && sort.isNotEmpty) 'sort': sort,
        'page': '$page',
        'page_size': '$pageSize',
      },
    );
    return CloudSnapshotPage.fromJson(resp);
  }

  Future<CloudChangesPage> fetchChanges({required int sinceSeq, int limit = 200}) async {
    final resp = await api.getJson(
      '/api/v1/library/changes',
      query: {'since_seq': '$sinceSeq', 'limit': '$limit'},
    );
    return CloudChangesPage.fromJson(resp);
  }

  Future<Map<String, dynamic>> fetchItemDetail(int itemId) async {
    final resp = await api.getJson('/api/v1/items/$itemId');
    final item = resp['item'];
    return item is Map ? Map<String, dynamic>.from(item) : const {};
  }

  /// Opens the `/api/v1/events` SSE stream and yields parsed [CloudSseEvent]s.
  Stream<CloudSseEvent> watchEvents() async* {
    final streamed = await api.openEventStream('/api/v1/events');
    if (streamed.statusCode < 200 || streamed.statusCode >= 300) {
      throw CloudApiException(
        statusCode: streamed.statusCode,
        errorCode: 'sse_failed',
        message: 'SSE connection failed (${streamed.statusCode})',
      );
    }

    var currentId = '';
    var currentEvent = 'message';
    final dataLines = <String>[];

    await for (final line in streamed.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (line.isEmpty) {
        if (dataLines.isNotEmpty) {
          final rawData = dataLines.join('\n');
          Map<String, dynamic> parsed = const {};
          try {
            final decoded = jsonDecode(rawData);
            if (decoded is Map) parsed = Map<String, dynamic>.from(decoded);
          } catch (_) {}
          yield CloudSseEvent(id: currentId, type: currentEvent, data: parsed);
        }
        currentId = '';
        currentEvent = 'message';
        dataLines.clear();
        continue;
      }
      if (line.startsWith(':')) continue;
      if (line.startsWith('id:')) {
        currentId = line.substring(3).trim();
      } else if (line.startsWith('event:')) {
        currentEvent = line.substring(6).trim();
      } else if (line.startsWith('data:')) {
        dataLines.add(line.substring(5).trim());
      }
    }
  }

  // ─── User Playback Progress, Favorites, Prefs & Lists ───────────────────

  Future<List<Map<String, dynamic>>> listProgress({String? workKey, int limit = 100, int offset = 0}) async {
    final resp = await api.getJson(
      '/api/v1/progress',
      query: {
        if (workKey != null && workKey.isNotEmpty) 'work_key': workKey,
        'limit': '$limit',
        'offset': '$offset',
      },
    );
    return [
      for (final i in (resp['items'] as List? ?? const []))
        if (i is Map) Map<String, dynamic>.from(i),
    ];
  }

  Future<Map<String, dynamic>> upsertProgress({
    required String workKey,
    int seasonNumber = 0,
    int episodeNumber = 0,
    int? lastFileId,
    required int positionMs,
    int? durationMs,
    bool? watched,
  }) async {
    final resp = await api.postJson(
      '/api/v1/progress',
      body: {
        'work_key': workKey,
        if (seasonNumber > 0) 'season_number': seasonNumber,
        if (episodeNumber > 0) 'episode_number': episodeNumber,
        'last_file_id': ?lastFileId,
        'position_ms': positionMs,
        'duration_ms': ?durationMs,
        'watched': ?watched,
      },
    );
    final p = resp['progress'];
    return p is Map ? Map<String, dynamic>.from(p) : const {};
  }

  Future<List<Map<String, dynamic>>> listContinueWatching({int limit = 30}) async {
    final resp = await api.getJson('/api/v1/continue-watching', query: {'limit': '$limit'});
    return [
      for (final i in (resp['items'] as List? ?? const []))
        if (i is Map) Map<String, dynamic>.from(i),
    ];
  }

  Future<void> hideContinueWatching(String progressKey) async {
    await api.postJson('/api/v1/continue-watching/${Uri.encodeComponent(progressKey)}/hide');
  }

  Future<List<Map<String, dynamic>>> listFavorites() async {
    final resp = await api.getJson('/api/v1/favorites');
    return [
      for (final i in (resp['items'] as List? ?? const []))
        if (i is Map) Map<String, dynamic>.from(i),
    ];
  }

  Future<void> addFavorite(String workKey) async {
    await api.putJson('/api/v1/favorites/${Uri.encodeComponent(workKey)}');
  }

  Future<void> removeFavorite(String workKey) async {
    await api.deleteJson('/api/v1/favorites/${Uri.encodeComponent(workKey)}');
  }

  // ─── Unmatched, Metadata Search & Manual Match (S4) ─────────────────────

  Future<({List<Map<String, dynamic>> items, int total})> listUnmatched({
    int page = 1,
    int pageSize = 100,
    String? sourceId,
    String? state,
  }) async {
    final resp = await api.getJson(
      '/api/v1/library/unmatched',
      query: {
        'page': '$page',
        'page_size': '$pageSize',
        if (sourceId != null && sourceId.isNotEmpty) 'source_id': sourceId,
        if (state != null && state.isNotEmpty) 'state': state,
      },
    );
    return (
      items: [
        for (final i in (resp['items'] as List? ?? const []))
          if (i is Map) Map<String, dynamic>.from(i),
      ],
      total: (resp['total'] as num?)?.toInt() ?? 0,
    );
  }

  Future<int> ignoreUnmatched({List<int>? fileIds, String? sourceId, String? pathPrefix}) async {
    final resp = await api.postJson(
      '/api/v1/library/unmatched/ignore',
      body: {
        if (fileIds != null && fileIds.isNotEmpty) 'file_ids': fileIds,
        if (sourceId != null && sourceId.isNotEmpty) 'source_id': sourceId,
        if (pathPrefix != null && pathPrefix.isNotEmpty) 'path_prefix': pathPrefix,
      },
    );
    return (resp['updated'] as num?)?.toInt() ?? 0;
  }

  Future<List<Map<String, dynamic>>> searchMetadata({
    required String query,
    String kind = 'movie',
    String? provider,
    int? year,
  }) async {
    final resp = await api.getJson(
      '/api/v1/metadata/search',
      query: {
        'q': query.trim(),
        'kind': kind,
        if (provider != null && provider.isNotEmpty && provider != 'all') 'provider': provider,
        if (year != null && year > 0) 'year': '$year',
      },
    );
    return [
      for (final r in (resp['results'] as List? ?? const []))
        if (r is Map) Map<String, dynamic>.from(r),
    ];
  }

  Future<Map<String, dynamic>> applyManualMatch({
    List<int>? fileIds,
    int? itemId,
    String? sourceId,
    String? pathPrefix,
    required String provider,
    required String externalId,
    required String kind,
    bool createRule = true,
    bool lock = true,
  }) async {
    return api.postJson(
      '/api/v1/library/manual-match',
      body: {
        if (fileIds != null && fileIds.isNotEmpty) 'file_ids': fileIds,
        'item_id': ?itemId,
        if (sourceId != null && sourceId.isNotEmpty) 'source_id': sourceId,
        if (pathPrefix != null && pathPrefix.isNotEmpty) 'path_prefix': pathPrefix,
        'provider': provider,
        'external_id': externalId,
        'kind': kind,
        'create_rule': createRule,
        'lock': lock,
      },
    );
  }

  Future<List<Map<String, dynamic>>> listMatchRules({String? sourceId}) async {
    final resp = await api.getJson(
      '/api/v1/match-rules',
      query: {if (sourceId != null && sourceId.isNotEmpty) 'source_id': sourceId},
    );
    return [
      for (final r in (resp['rules'] as List? ?? const []))
        if (r is Map) Map<String, dynamic>.from(r),
    ];
  }

  Future<void> deleteMatchRule(String ruleId) async {
    await api.deleteJson('/api/v1/match-rules/${Uri.encodeComponent(ruleId)}');
  }
}
