enum AppLoginMode {
  offline,
  selfHosted;

  static AppLoginMode? fromStorage(String? value) => switch (value) {
    'offline' => AppLoginMode.offline,
    'self_hosted' => AppLoginMode.selfHosted,
    _ => null,
  };

  String get storageValue => switch (this) {
    AppLoginMode.offline => 'offline',
    AppLoginMode.selfHosted => 'self_hosted',
  };
}

class SelfHostedServerBootstrap {
  const SelfHostedServerBootstrap({
    required this.serverUrl,
    required this.initialized,
    required this.serverName,
    required this.accentTheme,
    required this.version,
    this.protocolVersion = 0,
    this.minProtocolVersion = 0,
    this.registrationMode = 'closed',
  });

  final String serverUrl;
  final bool initialized;
  final String serverName;
  final String accentTheme;
  final String version;
  final int protocolVersion;
  final int minProtocolVersion;
  final String registrationMode; // open | invite | closed

  bool get isMediaLibraryV1 => protocolVersion >= 1;
  bool get allowsRegistration => registrationMode == 'open' || registrationMode == 'invite';
  bool get requiresInviteCode => registrationMode == 'invite';
}

class SelfHostedSession {
  SelfHostedSession({
    required String serverUrl,
    required this.username,
    required this.accessToken,
    this.tokenId,
    this.serverName,
    this.accentTheme,
    this.expiresAt,
    this.householdId,
    this.memberId,
    this.deviceId,
    this.deviceClass,
    this.masterKeyB64,
    this.keyEpoch = 1,
  }) : serverUrl = normalizeServerUrl(serverUrl);

  final String serverUrl;
  final String username;
  final String accessToken;
  final String? tokenId;
  final String? serverName;
  final String? accentTheme;
  final int? expiresAt;
  final String? householdId;
  final String? memberId;
  final String? deviceId;
  final String? deviceClass;
  final String? masterKeyB64;
  final int keyEpoch;

  static String normalizeServerUrl(String raw) {
    var url = raw.trim();
    if (url.isNotEmpty && !url.startsWith('http://') && !url.startsWith('https://')) {
      url = 'http://$url';
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  Map<String, dynamic> toJson() => {
    'server_url': serverUrl,
    'username': username,
    'access_token': accessToken,
    if (tokenId != null) 'token_id': tokenId,
    if (serverName != null) 'server_name': serverName,
    if (accentTheme != null) 'accent_theme': accentTheme,
    if (expiresAt != null) 'expires_at': expiresAt,
    if (householdId != null) 'household_id': householdId,
    if (memberId != null) 'member_id': memberId,
    if (deviceId != null) 'device_id': deviceId,
    if (deviceClass != null) 'device_class': deviceClass,
    if (masterKeyB64 != null) 'master_key_b64': masterKeyB64,
    'key_epoch': keyEpoch,
  };

  factory SelfHostedSession.fromJson(Map<String, dynamic> json) => SelfHostedSession(
    serverUrl: json['server_url'] as String? ?? '',
    username: json['username'] as String? ?? '',
    accessToken: json['access_token'] as String? ?? '',
    tokenId: json['token_id'] as String?,
    serverName: json['server_name'] as String?,
    accentTheme: json['accent_theme'] as String?,
    expiresAt: (json['expires_at'] as num?)?.toInt(),
    householdId: json['household_id'] as String?,
    memberId: json['member_id'] as String?,
    deviceId: json['device_id'] as String?,
    deviceClass: json['device_class'] as String?,
    masterKeyB64: json['master_key_b64'] as String?,
    keyEpoch: (json['key_epoch'] as num?)?.toInt() ?? 1,
  );
}

enum SelfHostedAuthErrorKind { invalidUrl, invalidCredentials, uninitializedServer, network, serverError }

class SelfHostedAuthException implements Exception {
  const SelfHostedAuthException(this.kind, this.message, {this.statusCode});

  final SelfHostedAuthErrorKind kind;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'SelfHostedAuthException($kind, $statusCode): $message';
}
