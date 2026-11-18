import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../../database/app_database.dart';
import 'sync_crypto.dart';

class SyncApiException implements Exception {
  const SyncApiException(this.statusCode, this.message);

  final int statusCode;
  final String message;

  @override
  String toString() => 'SyncApiException($statusCode): $message';
}

class SyncAuthResult {
  const SyncAuthResult({
    required this.userId,
    required this.username,
    required this.accessToken,
    required this.kdfSalt,
    required this.kdfParams,
    required this.encryptedMasterKeyBackup,
    required this.settings,
    required this.serverTimeMs,
  });

  final String userId;
  final String username;
  final String accessToken;
  final String kdfSalt;
  final SyncKdfParams kdfParams;
  final String encryptedMasterKeyBackup;
  final Map<String, Object?> settings;
  final int serverTimeMs;
}

class SyncQrCreateResult {
  const SyncQrCreateResult({required this.sessionId, required this.expiresAtMs});

  final String sessionId;
  final int expiresAtMs;
}

class SyncQrPollResult {
  const SyncQrPollResult({
    required this.status,
    required this.expiresAtMs,
    this.userId,
    this.username,
    this.accessToken,
    this.sealedMasterKey,
    this.settings = const {},
    this.serverTimeMs = 0,
  });

  final String status;
  final int expiresAtMs;
  final String? userId;
  final String? username;
  final String? accessToken;
  final String? sealedMasterKey;
  final Map<String, Object?> settings;
  final int serverTimeMs;
}

class SyncPullResult {
  const SyncPullResult({
    required this.serverTimeMs,
    required this.currentMaxSeq,
    required this.nextSeq,
    required this.hasMore,
    required this.resetRequired,
    required this.userSettings,
    required this.sources,
    required this.works,
    required this.files,
    required this.workPrefs,
    required this.watchProgress,
    this.lists = const [],
  });

  final int serverTimeMs;
  final int currentMaxSeq;
  final int nextSeq;
  final bool hasMore;
  final bool resetRequired;
  final Map<String, Object?> userSettings;
  final List<Map<String, dynamic>> sources;
  final List<Map<String, dynamic>> works;
  final List<Map<String, dynamic>> files;
  final List<Map<String, dynamic>> workPrefs;
  final List<Map<String, dynamic>> watchProgress;
  final List<Map<String, dynamic>> lists;
}

class SyncPushResult {
  const SyncPushResult({required this.serverTimeMs, required this.acceptedOpIds, required this.remappedSources});

  final int serverTimeMs;
  final List<String> acceptedOpIds;
  final Map<String, String> remappedSources;
}

class SyncLeaseResult {
  const SyncLeaseResult({required this.acquired, required this.holderDeviceId, required this.expiresAtMs});

  final bool acquired;
  final String? holderDeviceId;
  final int expiresAtMs;
}

class SyncApiClient {
  SyncApiClient({http.Client? httpClient, this.requestTimeout = const Duration(seconds: 10)})
    : _http = httpClient ?? http.Client(),
      _ownsClient = httpClient == null;

  final http.Client _http;
  final bool _ownsClient;
  final Duration requestTimeout;

  void close() {
    if (_ownsClient) _http.close();
  }

  static String _base(String serverUrl) => serverUrl.trim().replaceAll(RegExp(r'/+$'), '');

  Future<int> checkHealth(String serverUrl) async {
    final json = await _requestJson('GET', '${_base(serverUrl)}/healthz');
    return (json['server_time_ms'] as num?)?.toInt() ?? 0;
  }

  Future<({bool allowRegistration, int maxEntitiesPerUser})> probeServer(String serverUrl) async {
    final json = await _requestJson(
      'GET',
      '${_base(serverUrl)}/api/v1/public/info',
      timeout: const Duration(seconds: 5),
    );
    return (
      allowRegistration: json['allow_registration'] != false,
      maxEntitiesPerUser: (json['max_entities_per_user'] as num?)?.toInt() ?? 0,
    );
  }

  Future<({String kdfSalt, SyncKdfParams kdfParams})> lookupKdf(String serverUrl, String username) async {
    final uri = Uri.parse('${_base(serverUrl)}/api/v1/auth/kdf').replace(queryParameters: {'username': username});
    final json = await _requestJson('GET', uri.toString());
    return (
      kdfSalt: json['kdf_salt'] as String,
      kdfParams: SyncKdfParams.fromJson((json['kdf_params'] as Map<String, dynamic>?) ?? const {}),
    );
  }

  Future<SyncAuthResult> register({
    required String serverUrl,
    required String username,
    required String authVerifier,
    required String kdfSalt,
    required SyncKdfParams kdfParams,
    required String encryptedMasterKeyBackup,
    required String deviceId,
    Map<String, Object?> settings = const {},
  }) async {
    final json = await _requestJson(
      'POST',
      '${_base(serverUrl)}/api/v1/auth/register',
      body: {
        'username': username,
        'auth_verifier': authVerifier,
        'kdf_salt': kdfSalt,
        'kdf_params': kdfParams.toJson(),
        'encrypted_master_key_backup': encryptedMasterKeyBackup,
        'settings': settings,
        'device_id': deviceId,
      },
    );
    return _parseAuth(json);
  }

  Future<SyncAuthResult> login({
    required String serverUrl,
    required String username,
    required String authVerifier,
    required String deviceId,
  }) async {
    final json = await _requestJson(
      'POST',
      '${_base(serverUrl)}/api/v1/auth/login',
      body: {'username': username, 'auth_verifier': authVerifier, 'device_id': deviceId},
    );
    return _parseAuth(json);
  }

  Future<SyncQrCreateResult> createQrSession(
    String serverUrl, {
    required String tvPubKey,
    required String deviceName,
  }) async {
    final json = await _requestJson(
      'POST',
      '${_base(serverUrl)}/api/v1/auth/qr/create',
      body: {'tv_pub_key': tvPubKey, 'device_name': deviceName},
    );
    return SyncQrCreateResult(
      sessionId: json['session_id'] as String,
      expiresAtMs: (json['expires_at_ms'] as num).toInt(),
    );
  }

  Future<void> confirmQrSession(
    String serverUrl,
    String accessToken, {
    required String sessionId,
    required String sealedMasterKey,
    required String deviceId,
  }) async {
    await _requestJson(
      'POST',
      '${_base(serverUrl)}/api/v1/auth/qr/confirm',
      accessToken: accessToken,
      body: {'session_id': sessionId, 'sealed_master_key': sealedMasterKey, 'device_id': deviceId},
    );
  }

  Future<SyncQrPollResult> pollQrSession(String serverUrl, String sessionId) async {
    final uri = Uri.parse(
      '${_base(serverUrl)}/api/v1/auth/qr/poll',
    ).replace(queryParameters: {'session_id': sessionId});
    final json = await _requestJson('GET', uri.toString());
    return SyncQrPollResult(
      status: json['status'] as String,
      expiresAtMs: (json['expires_at_ms'] as num?)?.toInt() ?? 0,
      userId: json['user_id'] as String?,
      username: json['username'] as String?,
      accessToken: json['access_token'] as String?,
      sealedMasterKey: json['sealed_master_key'] as String?,
      settings: _mapOf(json['settings']),
      serverTimeMs: (json['server_time_ms'] as num?)?.toInt() ?? 0,
    );
  }

  Future<SyncPullResult> pullDelta(
    String serverUrl,
    String accessToken, {
    required int sinceSeq,
    int limit = 500,
  }) async {
    final uri = Uri.parse(
      '${_base(serverUrl)}/api/v1/sync/pull',
    ).replace(queryParameters: {'since_seq': '$sinceSeq', 'limit': '$limit'});
    final json = await _requestJson('GET', uri.toString(), accessToken: accessToken);
    final data = (json['data'] as Map<String, dynamic>?) ?? const {};
    return SyncPullResult(
      serverTimeMs: (json['server_time_ms'] as num?)?.toInt() ?? 0,
      currentMaxSeq: (json['current_max_seq'] as num?)?.toInt() ?? 0,
      nextSeq: (json['next_seq'] as num?)?.toInt() ?? sinceSeq,
      hasMore: json['has_more'] == true,
      resetRequired: json['reset_required'] == true,
      userSettings: _mapOf(json['user_settings']),
      sources: _listOfMaps(data['sources']),
      works: _listOfMaps(data['works']),
      files: _listOfMaps(data['files']),
      workPrefs: _listOfMaps(data['work_prefs']),
      watchProgress: _listOfMaps(data['watch_progress']),
      lists: _listOfMaps(data['lists']),
    );
  }

  Future<SyncPushResult> pushMutations(
    String serverUrl,
    String accessToken, {
    required String deviceId,
    required List<SyncOutboxRow> mutations,
  }) async {
    final body = {
      'device_id': deviceId,
      'mutations': [
        for (final row in mutations)
          {
            'op_id': row.opId,
            'entity_type': row.entityType,
            'entity_key': row.entityKey,
            'payload': jsonDecode(row.payloadJson),
          },
      ],
    };
    final json = await _requestJson(
      'POST',
      '${_base(serverUrl)}/api/v1/sync/push',
      accessToken: accessToken,
      body: body,
      compressRequest: true,
    );
    final rawAccepted = json['accepted_op_ids'] as List<dynamic>? ?? const [];
    final rawRemaps = json['remapped_sources'] as Map<String, dynamic>? ?? const {};
    return SyncPushResult(
      serverTimeMs: (json['server_time_ms'] as num?)?.toInt() ?? 0,
      acceptedOpIds: [for (final item in rawAccepted) '$item'],
      remappedSources: {for (final entry in rawRemaps.entries) entry.key: '${entry.value}'},
    );
  }

  Future<SyncLeaseResult> tryAcquireScanLease(
    String serverUrl,
    String accessToken, {
    required String sourceId,
    required String deviceId,
    int ttlSec = 60,
  }) async {
    final json = await _requestJson(
      'POST',
      '${_base(serverUrl)}/api/v1/sync/lease',
      accessToken: accessToken,
      body: {'source_id': sourceId, 'device_id': deviceId, 'ttl_sec': ttlSec},
    );
    return SyncLeaseResult(
      acquired: json['acquired'] == true,
      holderDeviceId: json['holder_device_id'] as String?,
      expiresAtMs: (json['expires_at_ms'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> updateUserSettings(String serverUrl, String accessToken, Map<String, Object?> updates) async {
    await _requestJson('POST', '${_base(serverUrl)}/api/v1/user/settings', accessToken: accessToken, body: updates);
  }

  SyncAuthResult _parseAuth(Map<String, dynamic> json) => SyncAuthResult(
    userId: json['user_id'] as String,
    username: json['username'] as String,
    accessToken: json['access_token'] as String,
    kdfSalt: json['kdf_salt'] as String? ?? '',
    kdfParams: SyncKdfParams.fromJson((json['kdf_params'] as Map<String, dynamic>?) ?? const {}),
    encryptedMasterKeyBackup: json['encrypted_master_key_backup'] as String? ?? '',
    settings: _mapOf(json['settings']),
    serverTimeMs: (json['server_time_ms'] as num?)?.toInt() ?? 0,
  );

  static Map<String, Object?> _mapOf(Object? raw) =>
      raw is Map ? {for (final entry in raw.entries) '${entry.key}': entry.value} : const {};

  static List<Map<String, dynamic>> _listOfMaps(Object? raw) => raw is List
      ? [
          for (final entry in raw)
            if (entry is Map<String, dynamic>) entry,
        ]
      : const [];

  Future<Map<String, dynamic>> _requestJson(
    String method,
    String url, {
    String? accessToken,
    Object? body,
    bool compressRequest = false,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? requestTimeout;
    final req = http.Request(method, Uri.parse(url));
    req.headers['Accept'] = 'application/json';
    req.headers['Accept-Encoding'] = 'gzip';
    if (accessToken != null && accessToken.isNotEmpty) {
      req.headers['Authorization'] = 'Bearer $accessToken';
    }
    if (body != null) {
      req.headers['Content-Type'] = 'application/json; charset=utf-8';
      final rawBytes = utf8.encode(jsonEncode(body));
      if (compressRequest && rawBytes.length > 512) {
        req.headers['Content-Encoding'] = 'gzip';
        req.bodyBytes = gzip.encode(rawBytes);
      } else {
        req.bodyBytes = rawBytes;
      }
    }

    final streamed = await _http.send(req).timeout(effectiveTimeout);
    final resp = await http.Response.fromStream(streamed).timeout(effectiveTimeout);
    final rawText = utf8.decode(resp.bodyBytes);
    final decoded = rawText.isEmpty ? <String, dynamic>{} : jsonDecode(rawText) as Map<String, dynamic>;
    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      throw SyncApiException(resp.statusCode, decoded['message'] as String? ?? resp.reasonPhrase ?? 'HTTP error');
    }
    return decoded;
  }
}
