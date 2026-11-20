import 'dart:typed_data';

import 'cloud_api_client.dart';
import 'cloud_keyring.dart';

class CloudSourceFolder {
  const CloudSourceFolder({
    required this.id,
    required this.sourceId,
    required this.path,
    this.excludePaths = const [],
    this.libraryHint = '',
    this.baselineAt,
  });

  final String id;
  final String sourceId;
  final String path;
  final List<String> excludePaths;
  final String libraryHint;
  final int? baselineAt;

  factory CloudSourceFolder.fromJson(Map<String, dynamic> json) => CloudSourceFolder(
    id: json['id'] as String? ?? '',
    sourceId: json['source_id'] as String? ?? '',
    path: json['path'] as String? ?? '/',
    excludePaths: [for (final e in (json['exclude_paths'] as List? ?? const [])) '$e'],
    libraryHint: json['library_hint'] as String? ?? '',
    baselineAt: (json['baseline_at'] as num?)?.toInt(),
  );
}

class CloudCredentialMeta {
  const CloudCredentialMeta({
    required this.version,
    required this.keyEpoch,
    required this.status,
    required this.updatedByDevice,
    required this.updatedAt,
  });

  final int version;
  final int keyEpoch;
  final String status; // valid | expired | kicked
  final String updatedByDevice;
  final int updatedAt;

  bool get isValid => status == 'valid';

  factory CloudCredentialMeta.fromJson(Map<String, dynamic> json) => CloudCredentialMeta(
    version: (json['version'] as num?)?.toInt() ?? 0,
    keyEpoch: (json['key_epoch'] as num?)?.toInt() ?? 1,
    status: (json['status'] as String? ?? 'valid').toLowerCase(),
    updatedByDevice: json['updated_by_device'] as String? ?? '',
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
  );
}

class CloudSourceScanState {
  const CloudSourceScanState({
    this.incrementalWatermark = 0,
    this.lastFullScanAt,
    this.lastScanResult = '',
    this.updatedAt = 0,
  });

  final int incrementalWatermark;
  final int? lastFullScanAt;
  final String lastScanResult;
  final int updatedAt;

  factory CloudSourceScanState.fromJson(Map<String, dynamic> json) => CloudSourceScanState(
    incrementalWatermark: (json['incremental_watermark'] as num?)?.toInt() ?? 0,
    lastFullScanAt: (json['last_full_scan_at'] as num?)?.toInt(),
    lastScanResult: json['last_scan_result'] as String? ?? '',
    updatedAt: (json['updated_at'] as num?)?.toInt() ?? 0,
  );
}

class CloudSource {
  const CloudSource({
    required this.id,
    required this.kind,
    required this.name,
    required this.identityKey,
    required this.status,
    this.credentialMeta,
    this.scanState,
    this.folders = const [],
  });

  final String id;
  final String kind; // quark | webdav | emby | jellyfin
  final String name;
  final String identityKey;
  final String status;
  final CloudCredentialMeta? credentialMeta;
  final CloudSourceScanState? scanState;
  final List<CloudSourceFolder> folders;

  factory CloudSource.fromJson(Map<String, dynamic> json) {
    final credRaw = json['credential_meta'];
    final scanRaw = json['scan_state'];
    final foldersRaw = json['folders'];
    return CloudSource(
      id: json['id'] as String? ?? '',
      kind: (json['kind'] as String? ?? '').toLowerCase(),
      name: json['name'] as String? ?? '',
      identityKey: json['identity_key'] as String? ?? '',
      status: (json['status'] as String? ?? 'active').toLowerCase(),
      credentialMeta: credRaw is Map ? CloudCredentialMeta.fromJson(Map<String, dynamic>.from(credRaw)) : null,
      scanState: scanRaw is Map ? CloudSourceScanState.fromJson(Map<String, dynamic>.from(scanRaw)) : null,
      folders: [
        if (foldersRaw is List)
          for (final f in foldersRaw)
            if (f is Map) CloudSourceFolder.fromJson(Map<String, dynamic>.from(f)),
      ],
    );
  }
}

class DecryptedSourceCredential {
  const DecryptedSourceCredential({
    required this.sourceId,
    required this.version,
    required this.keyEpoch,
    required this.status,
    required this.payload,
  });

  final String sourceId;
  final int version;
  final int keyEpoch;
  final String status;
  final Map<String, dynamic> payload;
}

/// Manages cloud-registered media sources, folders, and E2EE credentials (S2).
class CloudSourceRepository {
  CloudSourceRepository({
    required this.api,
    required this.masterKeyProvider,
    this.keyEpoch = 1,
  });

  final CloudApiClient api;
  final Uint8List? Function() masterKeyProvider;
  final int keyEpoch;

  Uint8List _requireMasterKey() {
    final key = masterKeyProvider();
    if (key == null || key.length != CloudKeyring.keyLengthBytes) {
      throw StateError('Master E2EE key is not unlocked in current session');
    }
    return key;
  }

  Future<List<CloudSource>> listSources() async {
    final resp = await api.getJson('/api/v1/sources');
    final raw = resp['sources'];
    if (raw is! List) return const [];
    return [
      for (final item in raw)
        if (item is Map) CloudSource.fromJson(Map<String, dynamic>.from(item)),
    ];
  }

  Future<CloudSource> getSource(String sourceId) async {
    final resp = await api.getJson('/api/v1/sources/${Uri.encodeComponent(sourceId)}');
    final raw = resp['source'];
    if (raw is! Map) throw StateError('Missing source in response');
    return CloudSource.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<CloudSource> createSource({
    required String kind,
    required String name,
    required String normalizedIdentity,
    required Map<String, dynamic> credentialPayload,
    List<Map<String, dynamic>> folders = const [],
    bool confirmDuplicate = false,
  }) async {
    final hk = _requireMasterKey();
    final identityKey = CloudKeyring.computeIdentityKey(hk, normalizedIdentity);
    final ciphertext = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: credentialPayload,
    );
    final resp = await api.postJson(
      '/api/v1/sources',
      body: {
        'kind': kind,
        'name': name.trim(),
        'identity_key': identityKey,
        'ciphertext': ciphertext,
        'key_epoch': keyEpoch,
        if (confirmDuplicate) 'confirm_duplicate': true,
        if (folders.isNotEmpty) 'folders': folders,
      },
    );
    final raw = resp['source'];
    if (raw is! Map) throw StateError('Missing source in create response');
    return CloudSource.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<CloudSource> renameSource(String sourceId, String newName) async {
    final resp = await api.patchJson(
      '/api/v1/sources/${Uri.encodeComponent(sourceId)}',
      body: {'name': newName.trim()},
    );
    final raw = resp['source'];
    if (raw is! Map) throw StateError('Missing source in rename response');
    return CloudSource.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<void> deleteSource(String sourceId) async {
    await api.deleteJson('/api/v1/sources/${Uri.encodeComponent(sourceId)}');
  }

  Future<CloudSourceFolder> addFolder(
    String sourceId, {
    required String path,
    List<String> excludePaths = const [],
    String libraryHint = '',
  }) async {
    final resp = await api.postJson(
      '/api/v1/sources/${Uri.encodeComponent(sourceId)}/folders',
      body: {
        'path': path,
        if (excludePaths.isNotEmpty) 'exclude_paths': excludePaths,
        if (libraryHint.isNotEmpty) 'library_hint': libraryHint,
      },
    );
    final raw = resp['folder'];
    if (raw is! Map) throw StateError('Missing folder in response');
    return CloudSourceFolder.fromJson(Map<String, dynamic>.from(raw));
  }

  Future<void> deleteFolder(String sourceId, String folderId) async {
    await api.deleteJson(
      '/api/v1/sources/${Uri.encodeComponent(sourceId)}/folders/${Uri.encodeComponent(folderId)}',
    );
  }

  Future<DecryptedSourceCredential> fetchCredential(String sourceId) async {
    final hk = _requireMasterKey();
    final resp = await api.getJson('/api/v1/sources/${Uri.encodeComponent(sourceId)}/credential');
    final cred = resp['credential'];
    if (cred is! Map) throw StateError('Missing credential in response');
    final map = Map<String, dynamic>.from(cred);
    final ciphertext = map['ciphertext'] as String? ?? '';
    final payload = await CloudKeyring.decryptCredentialJson(
      masterKey: hk,
      ciphertextB64: ciphertext,
    );
    return DecryptedSourceCredential(
      sourceId: map['source_id'] as String? ?? sourceId,
      version: (map['version'] as num?)?.toInt() ?? 1,
      keyEpoch: (map['key_epoch'] as num?)?.toInt() ?? 1,
      status: (map['status'] as String? ?? 'valid').toLowerCase(),
      payload: payload,
    );
  }

  Future<int> updateCredential({
    required String sourceId,
    required int baseVersion,
    required Map<String, dynamic> credentialPayload,
    String mode = 'refresh',
    String? normalizedIdentity,
  }) async {
    final hk = _requireMasterKey();
    final ciphertext = await CloudKeyring.encryptCredentialJson(
      masterKey: hk,
      payload: credentialPayload,
    );
    final resp = await api.putJson(
      '/api/v1/sources/${Uri.encodeComponent(sourceId)}/credential',
      body: {
        'base_version': baseVersion,
        'ciphertext': ciphertext,
        'key_epoch': keyEpoch,
        'mode': mode,
        if (normalizedIdentity != null && normalizedIdentity.isNotEmpty)
          'identity_key': CloudKeyring.computeIdentityKey(hk, normalizedIdentity),
      },
    );
    final cred = resp['credential'];
    if (cred is Map) {
      return (cred['version'] as num?)?.toInt() ?? (baseVersion + 1);
    }
    return baseVersion + 1;
  }

  Future<void> reportCredentialStatus({
    required String sourceId,
    required String status, // expired | kicked | valid
    int? version,
  }) async {
    await api.postJson(
      '/api/v1/sources/${Uri.encodeComponent(sourceId)}/credential/status',
      body: {
        'status': status,
        if (version != null && version > 0) 'version': version,
      },
    );
  }
}
