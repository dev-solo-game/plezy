/// Which driver backs a mount.
enum StorageKind {
  local('local'),
  webdav('webdav'),
  quark('quark'),
  smb('smb');

  const StorageKind(this.id);

  final String id;

  static StorageKind? fromId(String id) {
    for (final kind in values) {
      if (kind.id == id) return kind;
    }
    return null;
  }
}

/// A user-configured storage location.
///
/// [config] holds non-sensitive settings and [secrets] holds credentials
/// (passwords, cookies). They are kept apart so the registry can encrypt the
/// secrets at rest and exports can leave them out.
class StorageMount {
  const StorageMount({
    required this.id,
    required this.kind,
    required this.displayName,
    this.config = const {},
    this.secrets = const {},
    this.createdAt,
  });

  final String id;
  final StorageKind kind;
  final String displayName;
  final Map<String, Object?> config;
  final Map<String, String> secrets;
  final DateTime? createdAt;

  StorageMount copyWith({String? displayName, Map<String, Object?>? config, Map<String, String>? secrets}) {
    return StorageMount(
      id: id,
      kind: kind,
      displayName: displayName ?? this.displayName,
      config: config ?? this.config,
      secrets: secrets ?? this.secrets,
      createdAt: createdAt,
    );
  }

  String? configString(String key) {
    final value = config[key];
    return value is String && value.isNotEmpty ? value : null;
  }

  int? configInt(String key) {
    final value = config[key];
    if (value is int) return value;
    if (value is num) return value.toInt();
    if (value is String) return int.tryParse(value);
    return null;
  }

  bool configBool(String key, {bool fallback = false}) {
    final value = config[key];
    return value is bool ? value : fallback;
  }

  String? secret(String key) {
    final value = secrets[key];
    return value != null && value.isNotEmpty ? value : null;
  }
}

/// Config and secret keys shared between the drivers and the mount editor.
abstract final class MountKeys {
  /// Local: absolute directory on this device. SMB: optional sub-folder of
  /// the share to treat as the mount root.
  static const String rootPath = 'rootPath';

  /// SMB: server name or address, the share on it, and an optional domain.
  static const String host = 'host';
  static const String share = 'share';
  static const String domain = 'domain';

  /// WebDAV: collection URL, e.g. `https://nas.example/dav/media`.
  static const String baseUrl = 'baseUrl';
  static const String username = 'username';
  static const String allowInsecureTls = 'allowInsecureTls';

  /// Quark: folder id to treat as the mount root. `0` is the drive root.
  static const String rootFolderId = 'rootFolderId';

  /// Quark: the path of [rootFolderId] as the user picked it. Display only;
  /// the id is what addresses the folder.
  static const String rootFolderPath = 'rootFolderPath';

  /// Quark: minimum gap between two API calls, in milliseconds.
  static const String requestIntervalMs = 'requestIntervalMs';

  /// Quark: which client's sign-in and API the mount uses; a
  /// `QuarkMode` name. Absent means the web client.
  static const String quarkMode = 'quarkMode';

  static const String quarkDownloadConnections = 'downloadConnections';
  static const String quarkDownloadChunkMiB = 'downloadChunkMiB';

  static const String secretPassword = 'password';
  static const String secretCookie = 'cookie';
}
