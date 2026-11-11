// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $DownloadedMediaTable extends DownloadedMedia
    with TableInfo<$DownloadedMediaTable, DownloadedMediaItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadedMediaTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _clientScopeIdMeta = const VerificationMeta(
    'clientScopeId',
  );
  @override
  late final GeneratedColumn<String> clientScopeId = GeneratedColumn<String>(
    'client_scope_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ratingKeyMeta = const VerificationMeta(
    'ratingKey',
  );
  @override
  late final GeneratedColumn<String> ratingKey = GeneratedColumn<String>(
    'rating_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _globalKeyMeta = const VerificationMeta(
    'globalKey',
  );
  @override
  late final GeneratedColumn<String> globalKey = GeneratedColumn<String>(
    'global_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _typeMeta = const VerificationMeta('type');
  @override
  late final GeneratedColumn<String> type = GeneratedColumn<String>(
    'type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentRatingKeyMeta = const VerificationMeta(
    'parentRatingKey',
  );
  @override
  late final GeneratedColumn<String> parentRatingKey = GeneratedColumn<String>(
    'parent_rating_key',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _grandparentRatingKeyMeta =
      const VerificationMeta('grandparentRatingKey');
  @override
  late final GeneratedColumn<String> grandparentRatingKey =
      GeneratedColumn<String>(
        'grandparent_rating_key',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<int> status = GeneratedColumn<int>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _progressMeta = const VerificationMeta(
    'progress',
  );
  @override
  late final GeneratedColumn<int> progress = GeneratedColumn<int>(
    'progress',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _totalBytesMeta = const VerificationMeta(
    'totalBytes',
  );
  @override
  late final GeneratedColumn<int> totalBytes = GeneratedColumn<int>(
    'total_bytes',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _downloadedBytesMeta = const VerificationMeta(
    'downloadedBytes',
  );
  @override
  late final GeneratedColumn<int> downloadedBytes = GeneratedColumn<int>(
    'downloaded_bytes',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _videoFilePathMeta = const VerificationMeta(
    'videoFilePath',
  );
  @override
  late final GeneratedColumn<String> videoFilePath = GeneratedColumn<String>(
    'video_file_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _additionalPartPathsMeta =
      const VerificationMeta('additionalPartPaths');
  @override
  late final GeneratedColumn<String> additionalPartPaths =
      GeneratedColumn<String>(
        'additional_part_paths',
        aliasedName,
        true,
        type: DriftSqlType.string,
        requiredDuringInsert: false,
      );
  static const VerificationMeta _safRootUriMeta = const VerificationMeta(
    'safRootUri',
  );
  @override
  late final GeneratedColumn<String> safRootUri = GeneratedColumn<String>(
    'saf_root_uri',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _thumbPathMeta = const VerificationMeta(
    'thumbPath',
  );
  @override
  late final GeneratedColumn<String> thumbPath = GeneratedColumn<String>(
    'thumb_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _downloadedAtMeta = const VerificationMeta(
    'downloadedAt',
  );
  @override
  late final GeneratedColumn<int> downloadedAt = GeneratedColumn<int>(
    'downloaded_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _errorMessageMeta = const VerificationMeta(
    'errorMessage',
  );
  @override
  late final GeneratedColumn<String> errorMessage = GeneratedColumn<String>(
    'error_message',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _retryCountMeta = const VerificationMeta(
    'retryCount',
  );
  @override
  late final GeneratedColumn<int> retryCount = GeneratedColumn<int>(
    'retry_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _bgTaskIdMeta = const VerificationMeta(
    'bgTaskId',
  );
  @override
  late final GeneratedColumn<String> bgTaskId = GeneratedColumn<String>(
    'bg_task_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaIndexMeta = const VerificationMeta(
    'mediaIndex',
  );
  @override
  late final GeneratedColumn<int> mediaIndex = GeneratedColumn<int>(
    'media_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _mediaSourceIdMeta = const VerificationMeta(
    'mediaSourceId',
  );
  @override
  late final GeneratedColumn<String> mediaSourceId = GeneratedColumn<String>(
    'media_source_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _libraryIdMeta = const VerificationMeta(
    'libraryId',
  );
  @override
  late final GeneratedColumn<String> libraryId = GeneratedColumn<String>(
    'library_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _libraryTitleMeta = const VerificationMeta(
    'libraryTitle',
  );
  @override
  late final GeneratedColumn<String> libraryTitle = GeneratedColumn<String>(
    'library_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    serverId,
    clientScopeId,
    ratingKey,
    globalKey,
    type,
    parentRatingKey,
    grandparentRatingKey,
    status,
    progress,
    totalBytes,
    downloadedBytes,
    videoFilePath,
    additionalPartPaths,
    safRootUri,
    thumbPath,
    downloadedAt,
    errorMessage,
    retryCount,
    bgTaskId,
    mediaIndex,
    mediaSourceId,
    libraryId,
    libraryTitle,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'downloaded_media';
  @override
  VerificationContext validateIntegrity(
    Insertable<DownloadedMediaItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('client_scope_id')) {
      context.handle(
        _clientScopeIdMeta,
        clientScopeId.isAcceptableOrUnknown(
          data['client_scope_id']!,
          _clientScopeIdMeta,
        ),
      );
    }
    if (data.containsKey('rating_key')) {
      context.handle(
        _ratingKeyMeta,
        ratingKey.isAcceptableOrUnknown(data['rating_key']!, _ratingKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_ratingKeyMeta);
    }
    if (data.containsKey('global_key')) {
      context.handle(
        _globalKeyMeta,
        globalKey.isAcceptableOrUnknown(data['global_key']!, _globalKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_globalKeyMeta);
    }
    if (data.containsKey('type')) {
      context.handle(
        _typeMeta,
        type.isAcceptableOrUnknown(data['type']!, _typeMeta),
      );
    } else if (isInserting) {
      context.missing(_typeMeta);
    }
    if (data.containsKey('parent_rating_key')) {
      context.handle(
        _parentRatingKeyMeta,
        parentRatingKey.isAcceptableOrUnknown(
          data['parent_rating_key']!,
          _parentRatingKeyMeta,
        ),
      );
    }
    if (data.containsKey('grandparent_rating_key')) {
      context.handle(
        _grandparentRatingKeyMeta,
        grandparentRatingKey.isAcceptableOrUnknown(
          data['grandparent_rating_key']!,
          _grandparentRatingKeyMeta,
        ),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('progress')) {
      context.handle(
        _progressMeta,
        progress.isAcceptableOrUnknown(data['progress']!, _progressMeta),
      );
    }
    if (data.containsKey('total_bytes')) {
      context.handle(
        _totalBytesMeta,
        totalBytes.isAcceptableOrUnknown(data['total_bytes']!, _totalBytesMeta),
      );
    }
    if (data.containsKey('downloaded_bytes')) {
      context.handle(
        _downloadedBytesMeta,
        downloadedBytes.isAcceptableOrUnknown(
          data['downloaded_bytes']!,
          _downloadedBytesMeta,
        ),
      );
    }
    if (data.containsKey('video_file_path')) {
      context.handle(
        _videoFilePathMeta,
        videoFilePath.isAcceptableOrUnknown(
          data['video_file_path']!,
          _videoFilePathMeta,
        ),
      );
    }
    if (data.containsKey('additional_part_paths')) {
      context.handle(
        _additionalPartPathsMeta,
        additionalPartPaths.isAcceptableOrUnknown(
          data['additional_part_paths']!,
          _additionalPartPathsMeta,
        ),
      );
    }
    if (data.containsKey('saf_root_uri')) {
      context.handle(
        _safRootUriMeta,
        safRootUri.isAcceptableOrUnknown(
          data['saf_root_uri']!,
          _safRootUriMeta,
        ),
      );
    }
    if (data.containsKey('thumb_path')) {
      context.handle(
        _thumbPathMeta,
        thumbPath.isAcceptableOrUnknown(data['thumb_path']!, _thumbPathMeta),
      );
    }
    if (data.containsKey('downloaded_at')) {
      context.handle(
        _downloadedAtMeta,
        downloadedAt.isAcceptableOrUnknown(
          data['downloaded_at']!,
          _downloadedAtMeta,
        ),
      );
    }
    if (data.containsKey('error_message')) {
      context.handle(
        _errorMessageMeta,
        errorMessage.isAcceptableOrUnknown(
          data['error_message']!,
          _errorMessageMeta,
        ),
      );
    }
    if (data.containsKey('retry_count')) {
      context.handle(
        _retryCountMeta,
        retryCount.isAcceptableOrUnknown(data['retry_count']!, _retryCountMeta),
      );
    }
    if (data.containsKey('bg_task_id')) {
      context.handle(
        _bgTaskIdMeta,
        bgTaskId.isAcceptableOrUnknown(data['bg_task_id']!, _bgTaskIdMeta),
      );
    }
    if (data.containsKey('media_index')) {
      context.handle(
        _mediaIndexMeta,
        mediaIndex.isAcceptableOrUnknown(data['media_index']!, _mediaIndexMeta),
      );
    }
    if (data.containsKey('media_source_id')) {
      context.handle(
        _mediaSourceIdMeta,
        mediaSourceId.isAcceptableOrUnknown(
          data['media_source_id']!,
          _mediaSourceIdMeta,
        ),
      );
    }
    if (data.containsKey('library_id')) {
      context.handle(
        _libraryIdMeta,
        libraryId.isAcceptableOrUnknown(data['library_id']!, _libraryIdMeta),
      );
    }
    if (data.containsKey('library_title')) {
      context.handle(
        _libraryTitleMeta,
        libraryTitle.isAcceptableOrUnknown(
          data['library_title']!,
          _libraryTitleMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DownloadedMediaItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadedMediaItem(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      )!,
      clientScopeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_scope_id'],
      ),
      ratingKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rating_key'],
      )!,
      globalKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}global_key'],
      )!,
      type: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}type'],
      )!,
      parentRatingKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parent_rating_key'],
      ),
      grandparentRatingKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}grandparent_rating_key'],
      ),
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}status'],
      )!,
      progress: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}progress'],
      )!,
      totalBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}total_bytes'],
      ),
      downloadedBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}downloaded_bytes'],
      )!,
      videoFilePath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}video_file_path'],
      ),
      additionalPartPaths: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}additional_part_paths'],
      ),
      safRootUri: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}saf_root_uri'],
      ),
      thumbPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}thumb_path'],
      ),
      downloadedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}downloaded_at'],
      ),
      errorMessage: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}error_message'],
      ),
      retryCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}retry_count'],
      )!,
      bgTaskId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bg_task_id'],
      ),
      mediaIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}media_index'],
      )!,
      mediaSourceId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}media_source_id'],
      ),
      libraryId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}library_id'],
      ),
      libraryTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}library_title'],
      ),
    );
  }

  @override
  $DownloadedMediaTable createAlias(String alias) {
    return $DownloadedMediaTable(attachedDatabase, alias);
  }
}

class DownloadedMediaItem extends DataClass
    implements Insertable<DownloadedMediaItem> {
  final int id;
  final String serverId;
  final String? clientScopeId;
  final String ratingKey;
  final String globalKey;
  final String type;
  final String? parentRatingKey;
  final String? grandparentRatingKey;
  final int status;
  final int progress;
  final int? totalBytes;
  final int downloadedBytes;
  final String? videoFilePath;

  /// Stored paths of the files after the first when the downloaded version is
  /// stacked across several files (Plex `Part 2`, `Part 3`), as a JSON array in
  /// playback order. Each entry has the same stored form as [videoFilePath]
  /// (relative path or SAF `content://` URI), or is null while that file is
  /// not stored yet. Null for single-file downloads and rows from before v24.
  final String? additionalPartPaths;
  final String? safRootUri;
  final String? thumbPath;
  final int? downloadedAt;
  final String? errorMessage;
  final int retryCount;
  final String? bgTaskId;
  final int mediaIndex;
  final String? mediaSourceId;

  /// Owning library identity, stamped at enqueue time so downloads can be
  /// grouped/filtered by library while offline. Plex items carry
  /// librarySectionID/Title natively; Jellyfin resolves them via ancestors.
  /// Null for rows enqueued before v23 or when resolution was skipped/failed.
  final String? libraryId;
  final String? libraryTitle;
  const DownloadedMediaItem({
    required this.id,
    required this.serverId,
    this.clientScopeId,
    required this.ratingKey,
    required this.globalKey,
    required this.type,
    this.parentRatingKey,
    this.grandparentRatingKey,
    required this.status,
    required this.progress,
    this.totalBytes,
    required this.downloadedBytes,
    this.videoFilePath,
    this.additionalPartPaths,
    this.safRootUri,
    this.thumbPath,
    this.downloadedAt,
    this.errorMessage,
    required this.retryCount,
    this.bgTaskId,
    required this.mediaIndex,
    this.mediaSourceId,
    this.libraryId,
    this.libraryTitle,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['server_id'] = Variable<String>(serverId);
    if (!nullToAbsent || clientScopeId != null) {
      map['client_scope_id'] = Variable<String>(clientScopeId);
    }
    map['rating_key'] = Variable<String>(ratingKey);
    map['global_key'] = Variable<String>(globalKey);
    map['type'] = Variable<String>(type);
    if (!nullToAbsent || parentRatingKey != null) {
      map['parent_rating_key'] = Variable<String>(parentRatingKey);
    }
    if (!nullToAbsent || grandparentRatingKey != null) {
      map['grandparent_rating_key'] = Variable<String>(grandparentRatingKey);
    }
    map['status'] = Variable<int>(status);
    map['progress'] = Variable<int>(progress);
    if (!nullToAbsent || totalBytes != null) {
      map['total_bytes'] = Variable<int>(totalBytes);
    }
    map['downloaded_bytes'] = Variable<int>(downloadedBytes);
    if (!nullToAbsent || videoFilePath != null) {
      map['video_file_path'] = Variable<String>(videoFilePath);
    }
    if (!nullToAbsent || additionalPartPaths != null) {
      map['additional_part_paths'] = Variable<String>(additionalPartPaths);
    }
    if (!nullToAbsent || safRootUri != null) {
      map['saf_root_uri'] = Variable<String>(safRootUri);
    }
    if (!nullToAbsent || thumbPath != null) {
      map['thumb_path'] = Variable<String>(thumbPath);
    }
    if (!nullToAbsent || downloadedAt != null) {
      map['downloaded_at'] = Variable<int>(downloadedAt);
    }
    if (!nullToAbsent || errorMessage != null) {
      map['error_message'] = Variable<String>(errorMessage);
    }
    map['retry_count'] = Variable<int>(retryCount);
    if (!nullToAbsent || bgTaskId != null) {
      map['bg_task_id'] = Variable<String>(bgTaskId);
    }
    map['media_index'] = Variable<int>(mediaIndex);
    if (!nullToAbsent || mediaSourceId != null) {
      map['media_source_id'] = Variable<String>(mediaSourceId);
    }
    if (!nullToAbsent || libraryId != null) {
      map['library_id'] = Variable<String>(libraryId);
    }
    if (!nullToAbsent || libraryTitle != null) {
      map['library_title'] = Variable<String>(libraryTitle);
    }
    return map;
  }

  DownloadedMediaCompanion toCompanion(bool nullToAbsent) {
    return DownloadedMediaCompanion(
      id: Value(id),
      serverId: Value(serverId),
      clientScopeId: clientScopeId == null && nullToAbsent
          ? const Value.absent()
          : Value(clientScopeId),
      ratingKey: Value(ratingKey),
      globalKey: Value(globalKey),
      type: Value(type),
      parentRatingKey: parentRatingKey == null && nullToAbsent
          ? const Value.absent()
          : Value(parentRatingKey),
      grandparentRatingKey: grandparentRatingKey == null && nullToAbsent
          ? const Value.absent()
          : Value(grandparentRatingKey),
      status: Value(status),
      progress: Value(progress),
      totalBytes: totalBytes == null && nullToAbsent
          ? const Value.absent()
          : Value(totalBytes),
      downloadedBytes: Value(downloadedBytes),
      videoFilePath: videoFilePath == null && nullToAbsent
          ? const Value.absent()
          : Value(videoFilePath),
      additionalPartPaths: additionalPartPaths == null && nullToAbsent
          ? const Value.absent()
          : Value(additionalPartPaths),
      safRootUri: safRootUri == null && nullToAbsent
          ? const Value.absent()
          : Value(safRootUri),
      thumbPath: thumbPath == null && nullToAbsent
          ? const Value.absent()
          : Value(thumbPath),
      downloadedAt: downloadedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(downloadedAt),
      errorMessage: errorMessage == null && nullToAbsent
          ? const Value.absent()
          : Value(errorMessage),
      retryCount: Value(retryCount),
      bgTaskId: bgTaskId == null && nullToAbsent
          ? const Value.absent()
          : Value(bgTaskId),
      mediaIndex: Value(mediaIndex),
      mediaSourceId: mediaSourceId == null && nullToAbsent
          ? const Value.absent()
          : Value(mediaSourceId),
      libraryId: libraryId == null && nullToAbsent
          ? const Value.absent()
          : Value(libraryId),
      libraryTitle: libraryTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(libraryTitle),
    );
  }

  factory DownloadedMediaItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadedMediaItem(
      id: serializer.fromJson<int>(json['id']),
      serverId: serializer.fromJson<String>(json['serverId']),
      clientScopeId: serializer.fromJson<String?>(json['clientScopeId']),
      ratingKey: serializer.fromJson<String>(json['ratingKey']),
      globalKey: serializer.fromJson<String>(json['globalKey']),
      type: serializer.fromJson<String>(json['type']),
      parentRatingKey: serializer.fromJson<String?>(json['parentRatingKey']),
      grandparentRatingKey: serializer.fromJson<String?>(
        json['grandparentRatingKey'],
      ),
      status: serializer.fromJson<int>(json['status']),
      progress: serializer.fromJson<int>(json['progress']),
      totalBytes: serializer.fromJson<int?>(json['totalBytes']),
      downloadedBytes: serializer.fromJson<int>(json['downloadedBytes']),
      videoFilePath: serializer.fromJson<String?>(json['videoFilePath']),
      additionalPartPaths: serializer.fromJson<String?>(
        json['additionalPartPaths'],
      ),
      safRootUri: serializer.fromJson<String?>(json['safRootUri']),
      thumbPath: serializer.fromJson<String?>(json['thumbPath']),
      downloadedAt: serializer.fromJson<int?>(json['downloadedAt']),
      errorMessage: serializer.fromJson<String?>(json['errorMessage']),
      retryCount: serializer.fromJson<int>(json['retryCount']),
      bgTaskId: serializer.fromJson<String?>(json['bgTaskId']),
      mediaIndex: serializer.fromJson<int>(json['mediaIndex']),
      mediaSourceId: serializer.fromJson<String?>(json['mediaSourceId']),
      libraryId: serializer.fromJson<String?>(json['libraryId']),
      libraryTitle: serializer.fromJson<String?>(json['libraryTitle']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'serverId': serializer.toJson<String>(serverId),
      'clientScopeId': serializer.toJson<String?>(clientScopeId),
      'ratingKey': serializer.toJson<String>(ratingKey),
      'globalKey': serializer.toJson<String>(globalKey),
      'type': serializer.toJson<String>(type),
      'parentRatingKey': serializer.toJson<String?>(parentRatingKey),
      'grandparentRatingKey': serializer.toJson<String?>(grandparentRatingKey),
      'status': serializer.toJson<int>(status),
      'progress': serializer.toJson<int>(progress),
      'totalBytes': serializer.toJson<int?>(totalBytes),
      'downloadedBytes': serializer.toJson<int>(downloadedBytes),
      'videoFilePath': serializer.toJson<String?>(videoFilePath),
      'additionalPartPaths': serializer.toJson<String?>(additionalPartPaths),
      'safRootUri': serializer.toJson<String?>(safRootUri),
      'thumbPath': serializer.toJson<String?>(thumbPath),
      'downloadedAt': serializer.toJson<int?>(downloadedAt),
      'errorMessage': serializer.toJson<String?>(errorMessage),
      'retryCount': serializer.toJson<int>(retryCount),
      'bgTaskId': serializer.toJson<String?>(bgTaskId),
      'mediaIndex': serializer.toJson<int>(mediaIndex),
      'mediaSourceId': serializer.toJson<String?>(mediaSourceId),
      'libraryId': serializer.toJson<String?>(libraryId),
      'libraryTitle': serializer.toJson<String?>(libraryTitle),
    };
  }

  DownloadedMediaItem copyWith({
    int? id,
    String? serverId,
    Value<String?> clientScopeId = const Value.absent(),
    String? ratingKey,
    String? globalKey,
    String? type,
    Value<String?> parentRatingKey = const Value.absent(),
    Value<String?> grandparentRatingKey = const Value.absent(),
    int? status,
    int? progress,
    Value<int?> totalBytes = const Value.absent(),
    int? downloadedBytes,
    Value<String?> videoFilePath = const Value.absent(),
    Value<String?> additionalPartPaths = const Value.absent(),
    Value<String?> safRootUri = const Value.absent(),
    Value<String?> thumbPath = const Value.absent(),
    Value<int?> downloadedAt = const Value.absent(),
    Value<String?> errorMessage = const Value.absent(),
    int? retryCount,
    Value<String?> bgTaskId = const Value.absent(),
    int? mediaIndex,
    Value<String?> mediaSourceId = const Value.absent(),
    Value<String?> libraryId = const Value.absent(),
    Value<String?> libraryTitle = const Value.absent(),
  }) => DownloadedMediaItem(
    id: id ?? this.id,
    serverId: serverId ?? this.serverId,
    clientScopeId: clientScopeId.present
        ? clientScopeId.value
        : this.clientScopeId,
    ratingKey: ratingKey ?? this.ratingKey,
    globalKey: globalKey ?? this.globalKey,
    type: type ?? this.type,
    parentRatingKey: parentRatingKey.present
        ? parentRatingKey.value
        : this.parentRatingKey,
    grandparentRatingKey: grandparentRatingKey.present
        ? grandparentRatingKey.value
        : this.grandparentRatingKey,
    status: status ?? this.status,
    progress: progress ?? this.progress,
    totalBytes: totalBytes.present ? totalBytes.value : this.totalBytes,
    downloadedBytes: downloadedBytes ?? this.downloadedBytes,
    videoFilePath: videoFilePath.present
        ? videoFilePath.value
        : this.videoFilePath,
    additionalPartPaths: additionalPartPaths.present
        ? additionalPartPaths.value
        : this.additionalPartPaths,
    safRootUri: safRootUri.present ? safRootUri.value : this.safRootUri,
    thumbPath: thumbPath.present ? thumbPath.value : this.thumbPath,
    downloadedAt: downloadedAt.present ? downloadedAt.value : this.downloadedAt,
    errorMessage: errorMessage.present ? errorMessage.value : this.errorMessage,
    retryCount: retryCount ?? this.retryCount,
    bgTaskId: bgTaskId.present ? bgTaskId.value : this.bgTaskId,
    mediaIndex: mediaIndex ?? this.mediaIndex,
    mediaSourceId: mediaSourceId.present
        ? mediaSourceId.value
        : this.mediaSourceId,
    libraryId: libraryId.present ? libraryId.value : this.libraryId,
    libraryTitle: libraryTitle.present ? libraryTitle.value : this.libraryTitle,
  );
  DownloadedMediaItem copyWithCompanion(DownloadedMediaCompanion data) {
    return DownloadedMediaItem(
      id: data.id.present ? data.id.value : this.id,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      clientScopeId: data.clientScopeId.present
          ? data.clientScopeId.value
          : this.clientScopeId,
      ratingKey: data.ratingKey.present ? data.ratingKey.value : this.ratingKey,
      globalKey: data.globalKey.present ? data.globalKey.value : this.globalKey,
      type: data.type.present ? data.type.value : this.type,
      parentRatingKey: data.parentRatingKey.present
          ? data.parentRatingKey.value
          : this.parentRatingKey,
      grandparentRatingKey: data.grandparentRatingKey.present
          ? data.grandparentRatingKey.value
          : this.grandparentRatingKey,
      status: data.status.present ? data.status.value : this.status,
      progress: data.progress.present ? data.progress.value : this.progress,
      totalBytes: data.totalBytes.present
          ? data.totalBytes.value
          : this.totalBytes,
      downloadedBytes: data.downloadedBytes.present
          ? data.downloadedBytes.value
          : this.downloadedBytes,
      videoFilePath: data.videoFilePath.present
          ? data.videoFilePath.value
          : this.videoFilePath,
      additionalPartPaths: data.additionalPartPaths.present
          ? data.additionalPartPaths.value
          : this.additionalPartPaths,
      safRootUri: data.safRootUri.present
          ? data.safRootUri.value
          : this.safRootUri,
      thumbPath: data.thumbPath.present ? data.thumbPath.value : this.thumbPath,
      downloadedAt: data.downloadedAt.present
          ? data.downloadedAt.value
          : this.downloadedAt,
      errorMessage: data.errorMessage.present
          ? data.errorMessage.value
          : this.errorMessage,
      retryCount: data.retryCount.present
          ? data.retryCount.value
          : this.retryCount,
      bgTaskId: data.bgTaskId.present ? data.bgTaskId.value : this.bgTaskId,
      mediaIndex: data.mediaIndex.present
          ? data.mediaIndex.value
          : this.mediaIndex,
      mediaSourceId: data.mediaSourceId.present
          ? data.mediaSourceId.value
          : this.mediaSourceId,
      libraryId: data.libraryId.present ? data.libraryId.value : this.libraryId,
      libraryTitle: data.libraryTitle.present
          ? data.libraryTitle.value
          : this.libraryTitle,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadedMediaItem(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('clientScopeId: $clientScopeId, ')
          ..write('ratingKey: $ratingKey, ')
          ..write('globalKey: $globalKey, ')
          ..write('type: $type, ')
          ..write('parentRatingKey: $parentRatingKey, ')
          ..write('grandparentRatingKey: $grandparentRatingKey, ')
          ..write('status: $status, ')
          ..write('progress: $progress, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('downloadedBytes: $downloadedBytes, ')
          ..write('videoFilePath: $videoFilePath, ')
          ..write('additionalPartPaths: $additionalPartPaths, ')
          ..write('safRootUri: $safRootUri, ')
          ..write('thumbPath: $thumbPath, ')
          ..write('downloadedAt: $downloadedAt, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('retryCount: $retryCount, ')
          ..write('bgTaskId: $bgTaskId, ')
          ..write('mediaIndex: $mediaIndex, ')
          ..write('mediaSourceId: $mediaSourceId, ')
          ..write('libraryId: $libraryId, ')
          ..write('libraryTitle: $libraryTitle')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    serverId,
    clientScopeId,
    ratingKey,
    globalKey,
    type,
    parentRatingKey,
    grandparentRatingKey,
    status,
    progress,
    totalBytes,
    downloadedBytes,
    videoFilePath,
    additionalPartPaths,
    safRootUri,
    thumbPath,
    downloadedAt,
    errorMessage,
    retryCount,
    bgTaskId,
    mediaIndex,
    mediaSourceId,
    libraryId,
    libraryTitle,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadedMediaItem &&
          other.id == this.id &&
          other.serverId == this.serverId &&
          other.clientScopeId == this.clientScopeId &&
          other.ratingKey == this.ratingKey &&
          other.globalKey == this.globalKey &&
          other.type == this.type &&
          other.parentRatingKey == this.parentRatingKey &&
          other.grandparentRatingKey == this.grandparentRatingKey &&
          other.status == this.status &&
          other.progress == this.progress &&
          other.totalBytes == this.totalBytes &&
          other.downloadedBytes == this.downloadedBytes &&
          other.videoFilePath == this.videoFilePath &&
          other.additionalPartPaths == this.additionalPartPaths &&
          other.safRootUri == this.safRootUri &&
          other.thumbPath == this.thumbPath &&
          other.downloadedAt == this.downloadedAt &&
          other.errorMessage == this.errorMessage &&
          other.retryCount == this.retryCount &&
          other.bgTaskId == this.bgTaskId &&
          other.mediaIndex == this.mediaIndex &&
          other.mediaSourceId == this.mediaSourceId &&
          other.libraryId == this.libraryId &&
          other.libraryTitle == this.libraryTitle);
}

class DownloadedMediaCompanion extends UpdateCompanion<DownloadedMediaItem> {
  final Value<int> id;
  final Value<String> serverId;
  final Value<String?> clientScopeId;
  final Value<String> ratingKey;
  final Value<String> globalKey;
  final Value<String> type;
  final Value<String?> parentRatingKey;
  final Value<String?> grandparentRatingKey;
  final Value<int> status;
  final Value<int> progress;
  final Value<int?> totalBytes;
  final Value<int> downloadedBytes;
  final Value<String?> videoFilePath;
  final Value<String?> additionalPartPaths;
  final Value<String?> safRootUri;
  final Value<String?> thumbPath;
  final Value<int?> downloadedAt;
  final Value<String?> errorMessage;
  final Value<int> retryCount;
  final Value<String?> bgTaskId;
  final Value<int> mediaIndex;
  final Value<String?> mediaSourceId;
  final Value<String?> libraryId;
  final Value<String?> libraryTitle;
  const DownloadedMediaCompanion({
    this.id = const Value.absent(),
    this.serverId = const Value.absent(),
    this.clientScopeId = const Value.absent(),
    this.ratingKey = const Value.absent(),
    this.globalKey = const Value.absent(),
    this.type = const Value.absent(),
    this.parentRatingKey = const Value.absent(),
    this.grandparentRatingKey = const Value.absent(),
    this.status = const Value.absent(),
    this.progress = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.downloadedBytes = const Value.absent(),
    this.videoFilePath = const Value.absent(),
    this.additionalPartPaths = const Value.absent(),
    this.safRootUri = const Value.absent(),
    this.thumbPath = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.bgTaskId = const Value.absent(),
    this.mediaIndex = const Value.absent(),
    this.mediaSourceId = const Value.absent(),
    this.libraryId = const Value.absent(),
    this.libraryTitle = const Value.absent(),
  });
  DownloadedMediaCompanion.insert({
    this.id = const Value.absent(),
    required String serverId,
    this.clientScopeId = const Value.absent(),
    required String ratingKey,
    required String globalKey,
    required String type,
    this.parentRatingKey = const Value.absent(),
    this.grandparentRatingKey = const Value.absent(),
    required int status,
    this.progress = const Value.absent(),
    this.totalBytes = const Value.absent(),
    this.downloadedBytes = const Value.absent(),
    this.videoFilePath = const Value.absent(),
    this.additionalPartPaths = const Value.absent(),
    this.safRootUri = const Value.absent(),
    this.thumbPath = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.errorMessage = const Value.absent(),
    this.retryCount = const Value.absent(),
    this.bgTaskId = const Value.absent(),
    this.mediaIndex = const Value.absent(),
    this.mediaSourceId = const Value.absent(),
    this.libraryId = const Value.absent(),
    this.libraryTitle = const Value.absent(),
  }) : serverId = Value(serverId),
       ratingKey = Value(ratingKey),
       globalKey = Value(globalKey),
       type = Value(type),
       status = Value(status);
  static Insertable<DownloadedMediaItem> custom({
    Expression<int>? id,
    Expression<String>? serverId,
    Expression<String>? clientScopeId,
    Expression<String>? ratingKey,
    Expression<String>? globalKey,
    Expression<String>? type,
    Expression<String>? parentRatingKey,
    Expression<String>? grandparentRatingKey,
    Expression<int>? status,
    Expression<int>? progress,
    Expression<int>? totalBytes,
    Expression<int>? downloadedBytes,
    Expression<String>? videoFilePath,
    Expression<String>? additionalPartPaths,
    Expression<String>? safRootUri,
    Expression<String>? thumbPath,
    Expression<int>? downloadedAt,
    Expression<String>? errorMessage,
    Expression<int>? retryCount,
    Expression<String>? bgTaskId,
    Expression<int>? mediaIndex,
    Expression<String>? mediaSourceId,
    Expression<String>? libraryId,
    Expression<String>? libraryTitle,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (serverId != null) 'server_id': serverId,
      if (clientScopeId != null) 'client_scope_id': clientScopeId,
      if (ratingKey != null) 'rating_key': ratingKey,
      if (globalKey != null) 'global_key': globalKey,
      if (type != null) 'type': type,
      if (parentRatingKey != null) 'parent_rating_key': parentRatingKey,
      if (grandparentRatingKey != null)
        'grandparent_rating_key': grandparentRatingKey,
      if (status != null) 'status': status,
      if (progress != null) 'progress': progress,
      if (totalBytes != null) 'total_bytes': totalBytes,
      if (downloadedBytes != null) 'downloaded_bytes': downloadedBytes,
      if (videoFilePath != null) 'video_file_path': videoFilePath,
      if (additionalPartPaths != null)
        'additional_part_paths': additionalPartPaths,
      if (safRootUri != null) 'saf_root_uri': safRootUri,
      if (thumbPath != null) 'thumb_path': thumbPath,
      if (downloadedAt != null) 'downloaded_at': downloadedAt,
      if (errorMessage != null) 'error_message': errorMessage,
      if (retryCount != null) 'retry_count': retryCount,
      if (bgTaskId != null) 'bg_task_id': bgTaskId,
      if (mediaIndex != null) 'media_index': mediaIndex,
      if (mediaSourceId != null) 'media_source_id': mediaSourceId,
      if (libraryId != null) 'library_id': libraryId,
      if (libraryTitle != null) 'library_title': libraryTitle,
    });
  }

  DownloadedMediaCompanion copyWith({
    Value<int>? id,
    Value<String>? serverId,
    Value<String?>? clientScopeId,
    Value<String>? ratingKey,
    Value<String>? globalKey,
    Value<String>? type,
    Value<String?>? parentRatingKey,
    Value<String?>? grandparentRatingKey,
    Value<int>? status,
    Value<int>? progress,
    Value<int?>? totalBytes,
    Value<int>? downloadedBytes,
    Value<String?>? videoFilePath,
    Value<String?>? additionalPartPaths,
    Value<String?>? safRootUri,
    Value<String?>? thumbPath,
    Value<int?>? downloadedAt,
    Value<String?>? errorMessage,
    Value<int>? retryCount,
    Value<String?>? bgTaskId,
    Value<int>? mediaIndex,
    Value<String?>? mediaSourceId,
    Value<String?>? libraryId,
    Value<String?>? libraryTitle,
  }) {
    return DownloadedMediaCompanion(
      id: id ?? this.id,
      serverId: serverId ?? this.serverId,
      clientScopeId: clientScopeId ?? this.clientScopeId,
      ratingKey: ratingKey ?? this.ratingKey,
      globalKey: globalKey ?? this.globalKey,
      type: type ?? this.type,
      parentRatingKey: parentRatingKey ?? this.parentRatingKey,
      grandparentRatingKey: grandparentRatingKey ?? this.grandparentRatingKey,
      status: status ?? this.status,
      progress: progress ?? this.progress,
      totalBytes: totalBytes ?? this.totalBytes,
      downloadedBytes: downloadedBytes ?? this.downloadedBytes,
      videoFilePath: videoFilePath ?? this.videoFilePath,
      additionalPartPaths: additionalPartPaths ?? this.additionalPartPaths,
      safRootUri: safRootUri ?? this.safRootUri,
      thumbPath: thumbPath ?? this.thumbPath,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      errorMessage: errorMessage ?? this.errorMessage,
      retryCount: retryCount ?? this.retryCount,
      bgTaskId: bgTaskId ?? this.bgTaskId,
      mediaIndex: mediaIndex ?? this.mediaIndex,
      mediaSourceId: mediaSourceId ?? this.mediaSourceId,
      libraryId: libraryId ?? this.libraryId,
      libraryTitle: libraryTitle ?? this.libraryTitle,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (clientScopeId.present) {
      map['client_scope_id'] = Variable<String>(clientScopeId.value);
    }
    if (ratingKey.present) {
      map['rating_key'] = Variable<String>(ratingKey.value);
    }
    if (globalKey.present) {
      map['global_key'] = Variable<String>(globalKey.value);
    }
    if (type.present) {
      map['type'] = Variable<String>(type.value);
    }
    if (parentRatingKey.present) {
      map['parent_rating_key'] = Variable<String>(parentRatingKey.value);
    }
    if (grandparentRatingKey.present) {
      map['grandparent_rating_key'] = Variable<String>(
        grandparentRatingKey.value,
      );
    }
    if (status.present) {
      map['status'] = Variable<int>(status.value);
    }
    if (progress.present) {
      map['progress'] = Variable<int>(progress.value);
    }
    if (totalBytes.present) {
      map['total_bytes'] = Variable<int>(totalBytes.value);
    }
    if (downloadedBytes.present) {
      map['downloaded_bytes'] = Variable<int>(downloadedBytes.value);
    }
    if (videoFilePath.present) {
      map['video_file_path'] = Variable<String>(videoFilePath.value);
    }
    if (additionalPartPaths.present) {
      map['additional_part_paths'] = Variable<String>(
        additionalPartPaths.value,
      );
    }
    if (safRootUri.present) {
      map['saf_root_uri'] = Variable<String>(safRootUri.value);
    }
    if (thumbPath.present) {
      map['thumb_path'] = Variable<String>(thumbPath.value);
    }
    if (downloadedAt.present) {
      map['downloaded_at'] = Variable<int>(downloadedAt.value);
    }
    if (errorMessage.present) {
      map['error_message'] = Variable<String>(errorMessage.value);
    }
    if (retryCount.present) {
      map['retry_count'] = Variable<int>(retryCount.value);
    }
    if (bgTaskId.present) {
      map['bg_task_id'] = Variable<String>(bgTaskId.value);
    }
    if (mediaIndex.present) {
      map['media_index'] = Variable<int>(mediaIndex.value);
    }
    if (mediaSourceId.present) {
      map['media_source_id'] = Variable<String>(mediaSourceId.value);
    }
    if (libraryId.present) {
      map['library_id'] = Variable<String>(libraryId.value);
    }
    if (libraryTitle.present) {
      map['library_title'] = Variable<String>(libraryTitle.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadedMediaCompanion(')
          ..write('id: $id, ')
          ..write('serverId: $serverId, ')
          ..write('clientScopeId: $clientScopeId, ')
          ..write('ratingKey: $ratingKey, ')
          ..write('globalKey: $globalKey, ')
          ..write('type: $type, ')
          ..write('parentRatingKey: $parentRatingKey, ')
          ..write('grandparentRatingKey: $grandparentRatingKey, ')
          ..write('status: $status, ')
          ..write('progress: $progress, ')
          ..write('totalBytes: $totalBytes, ')
          ..write('downloadedBytes: $downloadedBytes, ')
          ..write('videoFilePath: $videoFilePath, ')
          ..write('additionalPartPaths: $additionalPartPaths, ')
          ..write('safRootUri: $safRootUri, ')
          ..write('thumbPath: $thumbPath, ')
          ..write('downloadedAt: $downloadedAt, ')
          ..write('errorMessage: $errorMessage, ')
          ..write('retryCount: $retryCount, ')
          ..write('bgTaskId: $bgTaskId, ')
          ..write('mediaIndex: $mediaIndex, ')
          ..write('mediaSourceId: $mediaSourceId, ')
          ..write('libraryId: $libraryId, ')
          ..write('libraryTitle: $libraryTitle')
          ..write(')'))
        .toString();
  }
}

class $DownloadOwnersTable extends DownloadOwners
    with TableInfo<$DownloadOwnersTable, DownloadOwnerItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadOwnersTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _globalKeyMeta = const VerificationMeta(
    'globalKey',
  );
  @override
  late final GeneratedColumn<String> globalKey = GeneratedColumn<String>(
    'global_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _backendMeta = const VerificationMeta(
    'backend',
  );
  @override
  late final GeneratedColumn<String> backend = GeneratedColumn<String>(
    'backend',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _clientScopeIdMeta = const VerificationMeta(
    'clientScopeId',
  );
  @override
  late final GeneratedColumn<String> clientScopeId = GeneratedColumn<String>(
    'client_scope_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    globalKey,
    backend,
    clientScopeId,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'download_owners';
  @override
  VerificationContext validateIntegrity(
    Insertable<DownloadOwnerItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('global_key')) {
      context.handle(
        _globalKeyMeta,
        globalKey.isAcceptableOrUnknown(data['global_key']!, _globalKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_globalKeyMeta);
    }
    if (data.containsKey('backend')) {
      context.handle(
        _backendMeta,
        backend.isAcceptableOrUnknown(data['backend']!, _backendMeta),
      );
    }
    if (data.containsKey('client_scope_id')) {
      context.handle(
        _clientScopeIdMeta,
        clientScopeId.isAcceptableOrUnknown(
          data['client_scope_id']!,
          _clientScopeIdMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId, globalKey};
  @override
  DownloadOwnerItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadOwnerItem(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      globalKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}global_key'],
      )!,
      backend: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}backend'],
      ),
      clientScopeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_scope_id'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $DownloadOwnersTable createAlias(String alias) {
    return $DownloadOwnersTable(attachedDatabase, alias);
  }
}

class DownloadOwnerItem extends DataClass
    implements Insertable<DownloadOwnerItem> {
  final String profileId;
  final String globalKey;
  final String? backend;
  final String? clientScopeId;
  final int createdAt;
  const DownloadOwnerItem({
    required this.profileId,
    required this.globalKey,
    this.backend,
    this.clientScopeId,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['global_key'] = Variable<String>(globalKey);
    if (!nullToAbsent || backend != null) {
      map['backend'] = Variable<String>(backend);
    }
    if (!nullToAbsent || clientScopeId != null) {
      map['client_scope_id'] = Variable<String>(clientScopeId);
    }
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  DownloadOwnersCompanion toCompanion(bool nullToAbsent) {
    return DownloadOwnersCompanion(
      profileId: Value(profileId),
      globalKey: Value(globalKey),
      backend: backend == null && nullToAbsent
          ? const Value.absent()
          : Value(backend),
      clientScopeId: clientScopeId == null && nullToAbsent
          ? const Value.absent()
          : Value(clientScopeId),
      createdAt: Value(createdAt),
    );
  }

  factory DownloadOwnerItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadOwnerItem(
      profileId: serializer.fromJson<String>(json['profileId']),
      globalKey: serializer.fromJson<String>(json['globalKey']),
      backend: serializer.fromJson<String?>(json['backend']),
      clientScopeId: serializer.fromJson<String?>(json['clientScopeId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'globalKey': serializer.toJson<String>(globalKey),
      'backend': serializer.toJson<String?>(backend),
      'clientScopeId': serializer.toJson<String?>(clientScopeId),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  DownloadOwnerItem copyWith({
    String? profileId,
    String? globalKey,
    Value<String?> backend = const Value.absent(),
    Value<String?> clientScopeId = const Value.absent(),
    int? createdAt,
  }) => DownloadOwnerItem(
    profileId: profileId ?? this.profileId,
    globalKey: globalKey ?? this.globalKey,
    backend: backend.present ? backend.value : this.backend,
    clientScopeId: clientScopeId.present
        ? clientScopeId.value
        : this.clientScopeId,
    createdAt: createdAt ?? this.createdAt,
  );
  DownloadOwnerItem copyWithCompanion(DownloadOwnersCompanion data) {
    return DownloadOwnerItem(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      globalKey: data.globalKey.present ? data.globalKey.value : this.globalKey,
      backend: data.backend.present ? data.backend.value : this.backend,
      clientScopeId: data.clientScopeId.present
          ? data.clientScopeId.value
          : this.clientScopeId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadOwnerItem(')
          ..write('profileId: $profileId, ')
          ..write('globalKey: $globalKey, ')
          ..write('backend: $backend, ')
          ..write('clientScopeId: $clientScopeId, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(profileId, globalKey, backend, clientScopeId, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadOwnerItem &&
          other.profileId == this.profileId &&
          other.globalKey == this.globalKey &&
          other.backend == this.backend &&
          other.clientScopeId == this.clientScopeId &&
          other.createdAt == this.createdAt);
}

class DownloadOwnersCompanion extends UpdateCompanion<DownloadOwnerItem> {
  final Value<String> profileId;
  final Value<String> globalKey;
  final Value<String?> backend;
  final Value<String?> clientScopeId;
  final Value<int> createdAt;
  final Value<int> rowid;
  const DownloadOwnersCompanion({
    this.profileId = const Value.absent(),
    this.globalKey = const Value.absent(),
    this.backend = const Value.absent(),
    this.clientScopeId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DownloadOwnersCompanion.insert({
    required String profileId,
    required String globalKey,
    this.backend = const Value.absent(),
    this.clientScopeId = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       globalKey = Value(globalKey),
       createdAt = Value(createdAt);
  static Insertable<DownloadOwnerItem> custom({
    Expression<String>? profileId,
    Expression<String>? globalKey,
    Expression<String>? backend,
    Expression<String>? clientScopeId,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (globalKey != null) 'global_key': globalKey,
      if (backend != null) 'backend': backend,
      if (clientScopeId != null) 'client_scope_id': clientScopeId,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DownloadOwnersCompanion copyWith({
    Value<String>? profileId,
    Value<String>? globalKey,
    Value<String?>? backend,
    Value<String?>? clientScopeId,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return DownloadOwnersCompanion(
      profileId: profileId ?? this.profileId,
      globalKey: globalKey ?? this.globalKey,
      backend: backend ?? this.backend,
      clientScopeId: clientScopeId ?? this.clientScopeId,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (globalKey.present) {
      map['global_key'] = Variable<String>(globalKey.value);
    }
    if (backend.present) {
      map['backend'] = Variable<String>(backend.value);
    }
    if (clientScopeId.present) {
      map['client_scope_id'] = Variable<String>(clientScopeId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadOwnersCompanion(')
          ..write('profileId: $profileId, ')
          ..write('globalKey: $globalKey, ')
          ..write('backend: $backend, ')
          ..write('clientScopeId: $clientScopeId, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DownloadQueueTable extends DownloadQueue
    with TableInfo<$DownloadQueueTable, DownloadQueueItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadQueueTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _mediaGlobalKeyMeta = const VerificationMeta(
    'mediaGlobalKey',
  );
  @override
  late final GeneratedColumn<String> mediaGlobalKey = GeneratedColumn<String>(
    'media_global_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _priorityMeta = const VerificationMeta(
    'priority',
  );
  @override
  late final GeneratedColumn<int> priority = GeneratedColumn<int>(
    'priority',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _downloadSubtitlesMeta = const VerificationMeta(
    'downloadSubtitles',
  );
  @override
  late final GeneratedColumn<bool> downloadSubtitles = GeneratedColumn<bool>(
    'download_subtitles',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("download_subtitles" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _downloadArtworkMeta = const VerificationMeta(
    'downloadArtwork',
  );
  @override
  late final GeneratedColumn<bool> downloadArtwork = GeneratedColumn<bool>(
    'download_artwork',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("download_artwork" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    mediaGlobalKey,
    priority,
    addedAt,
    downloadSubtitles,
    downloadArtwork,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'download_queue';
  @override
  VerificationContext validateIntegrity(
    Insertable<DownloadQueueItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('media_global_key')) {
      context.handle(
        _mediaGlobalKeyMeta,
        mediaGlobalKey.isAcceptableOrUnknown(
          data['media_global_key']!,
          _mediaGlobalKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_mediaGlobalKeyMeta);
    }
    if (data.containsKey('priority')) {
      context.handle(
        _priorityMeta,
        priority.isAcceptableOrUnknown(data['priority']!, _priorityMeta),
      );
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    if (data.containsKey('download_subtitles')) {
      context.handle(
        _downloadSubtitlesMeta,
        downloadSubtitles.isAcceptableOrUnknown(
          data['download_subtitles']!,
          _downloadSubtitlesMeta,
        ),
      );
    }
    if (data.containsKey('download_artwork')) {
      context.handle(
        _downloadArtworkMeta,
        downloadArtwork.isAcceptableOrUnknown(
          data['download_artwork']!,
          _downloadArtworkMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  DownloadQueueItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadQueueItem(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      mediaGlobalKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}media_global_key'],
      )!,
      priority: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}priority'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}added_at'],
      )!,
      downloadSubtitles: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}download_subtitles'],
      )!,
      downloadArtwork: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}download_artwork'],
      )!,
    );
  }

  @override
  $DownloadQueueTable createAlias(String alias) {
    return $DownloadQueueTable(attachedDatabase, alias);
  }
}

class DownloadQueueItem extends DataClass
    implements Insertable<DownloadQueueItem> {
  final int id;
  final String mediaGlobalKey;
  final int priority;
  final int addedAt;
  final bool downloadSubtitles;
  final bool downloadArtwork;
  const DownloadQueueItem({
    required this.id,
    required this.mediaGlobalKey,
    required this.priority,
    required this.addedAt,
    required this.downloadSubtitles,
    required this.downloadArtwork,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['media_global_key'] = Variable<String>(mediaGlobalKey);
    map['priority'] = Variable<int>(priority);
    map['added_at'] = Variable<int>(addedAt);
    map['download_subtitles'] = Variable<bool>(downloadSubtitles);
    map['download_artwork'] = Variable<bool>(downloadArtwork);
    return map;
  }

  DownloadQueueCompanion toCompanion(bool nullToAbsent) {
    return DownloadQueueCompanion(
      id: Value(id),
      mediaGlobalKey: Value(mediaGlobalKey),
      priority: Value(priority),
      addedAt: Value(addedAt),
      downloadSubtitles: Value(downloadSubtitles),
      downloadArtwork: Value(downloadArtwork),
    );
  }

  factory DownloadQueueItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadQueueItem(
      id: serializer.fromJson<int>(json['id']),
      mediaGlobalKey: serializer.fromJson<String>(json['mediaGlobalKey']),
      priority: serializer.fromJson<int>(json['priority']),
      addedAt: serializer.fromJson<int>(json['addedAt']),
      downloadSubtitles: serializer.fromJson<bool>(json['downloadSubtitles']),
      downloadArtwork: serializer.fromJson<bool>(json['downloadArtwork']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'mediaGlobalKey': serializer.toJson<String>(mediaGlobalKey),
      'priority': serializer.toJson<int>(priority),
      'addedAt': serializer.toJson<int>(addedAt),
      'downloadSubtitles': serializer.toJson<bool>(downloadSubtitles),
      'downloadArtwork': serializer.toJson<bool>(downloadArtwork),
    };
  }

  DownloadQueueItem copyWith({
    int? id,
    String? mediaGlobalKey,
    int? priority,
    int? addedAt,
    bool? downloadSubtitles,
    bool? downloadArtwork,
  }) => DownloadQueueItem(
    id: id ?? this.id,
    mediaGlobalKey: mediaGlobalKey ?? this.mediaGlobalKey,
    priority: priority ?? this.priority,
    addedAt: addedAt ?? this.addedAt,
    downloadSubtitles: downloadSubtitles ?? this.downloadSubtitles,
    downloadArtwork: downloadArtwork ?? this.downloadArtwork,
  );
  DownloadQueueItem copyWithCompanion(DownloadQueueCompanion data) {
    return DownloadQueueItem(
      id: data.id.present ? data.id.value : this.id,
      mediaGlobalKey: data.mediaGlobalKey.present
          ? data.mediaGlobalKey.value
          : this.mediaGlobalKey,
      priority: data.priority.present ? data.priority.value : this.priority,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      downloadSubtitles: data.downloadSubtitles.present
          ? data.downloadSubtitles.value
          : this.downloadSubtitles,
      downloadArtwork: data.downloadArtwork.present
          ? data.downloadArtwork.value
          : this.downloadArtwork,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadQueueItem(')
          ..write('id: $id, ')
          ..write('mediaGlobalKey: $mediaGlobalKey, ')
          ..write('priority: $priority, ')
          ..write('addedAt: $addedAt, ')
          ..write('downloadSubtitles: $downloadSubtitles, ')
          ..write('downloadArtwork: $downloadArtwork')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    mediaGlobalKey,
    priority,
    addedAt,
    downloadSubtitles,
    downloadArtwork,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadQueueItem &&
          other.id == this.id &&
          other.mediaGlobalKey == this.mediaGlobalKey &&
          other.priority == this.priority &&
          other.addedAt == this.addedAt &&
          other.downloadSubtitles == this.downloadSubtitles &&
          other.downloadArtwork == this.downloadArtwork);
}

class DownloadQueueCompanion extends UpdateCompanion<DownloadQueueItem> {
  final Value<int> id;
  final Value<String> mediaGlobalKey;
  final Value<int> priority;
  final Value<int> addedAt;
  final Value<bool> downloadSubtitles;
  final Value<bool> downloadArtwork;
  const DownloadQueueCompanion({
    this.id = const Value.absent(),
    this.mediaGlobalKey = const Value.absent(),
    this.priority = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.downloadSubtitles = const Value.absent(),
    this.downloadArtwork = const Value.absent(),
  });
  DownloadQueueCompanion.insert({
    this.id = const Value.absent(),
    required String mediaGlobalKey,
    this.priority = const Value.absent(),
    required int addedAt,
    this.downloadSubtitles = const Value.absent(),
    this.downloadArtwork = const Value.absent(),
  }) : mediaGlobalKey = Value(mediaGlobalKey),
       addedAt = Value(addedAt);
  static Insertable<DownloadQueueItem> custom({
    Expression<int>? id,
    Expression<String>? mediaGlobalKey,
    Expression<int>? priority,
    Expression<int>? addedAt,
    Expression<bool>? downloadSubtitles,
    Expression<bool>? downloadArtwork,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (mediaGlobalKey != null) 'media_global_key': mediaGlobalKey,
      if (priority != null) 'priority': priority,
      if (addedAt != null) 'added_at': addedAt,
      if (downloadSubtitles != null) 'download_subtitles': downloadSubtitles,
      if (downloadArtwork != null) 'download_artwork': downloadArtwork,
    });
  }

  DownloadQueueCompanion copyWith({
    Value<int>? id,
    Value<String>? mediaGlobalKey,
    Value<int>? priority,
    Value<int>? addedAt,
    Value<bool>? downloadSubtitles,
    Value<bool>? downloadArtwork,
  }) {
    return DownloadQueueCompanion(
      id: id ?? this.id,
      mediaGlobalKey: mediaGlobalKey ?? this.mediaGlobalKey,
      priority: priority ?? this.priority,
      addedAt: addedAt ?? this.addedAt,
      downloadSubtitles: downloadSubtitles ?? this.downloadSubtitles,
      downloadArtwork: downloadArtwork ?? this.downloadArtwork,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (mediaGlobalKey.present) {
      map['media_global_key'] = Variable<String>(mediaGlobalKey.value);
    }
    if (priority.present) {
      map['priority'] = Variable<int>(priority.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<int>(addedAt.value);
    }
    if (downloadSubtitles.present) {
      map['download_subtitles'] = Variable<bool>(downloadSubtitles.value);
    }
    if (downloadArtwork.present) {
      map['download_artwork'] = Variable<bool>(downloadArtwork.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadQueueCompanion(')
          ..write('id: $id, ')
          ..write('mediaGlobalKey: $mediaGlobalKey, ')
          ..write('priority: $priority, ')
          ..write('addedAt: $addedAt, ')
          ..write('downloadSubtitles: $downloadSubtitles, ')
          ..write('downloadArtwork: $downloadArtwork')
          ..write(')'))
        .toString();
  }
}

class $ApiCacheTable extends ApiCache
    with TableInfo<$ApiCacheTable, ApiCacheData> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ApiCacheTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _cacheKeyMeta = const VerificationMeta(
    'cacheKey',
  );
  @override
  late final GeneratedColumn<String> cacheKey = GeneratedColumn<String>(
    'cache_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _dataMeta = const VerificationMeta('data');
  @override
  late final GeneratedColumn<String> data = GeneratedColumn<String>(
    'data',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cachedAtMeta = const VerificationMeta(
    'cachedAt',
  );
  @override
  late final GeneratedColumn<DateTime> cachedAt = GeneratedColumn<DateTime>(
    'cached_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
    defaultValue: currentDateAndTime,
  );
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  @override
  late final GeneratedColumn<bool> pinned = GeneratedColumn<bool>(
    'pinned',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("pinned" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [cacheKey, data, cachedAt, pinned];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'api_cache';
  @override
  VerificationContext validateIntegrity(
    Insertable<ApiCacheData> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('cache_key')) {
      context.handle(
        _cacheKeyMeta,
        cacheKey.isAcceptableOrUnknown(data['cache_key']!, _cacheKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_cacheKeyMeta);
    }
    if (data.containsKey('data')) {
      context.handle(
        _dataMeta,
        this.data.isAcceptableOrUnknown(data['data']!, _dataMeta),
      );
    } else if (isInserting) {
      context.missing(_dataMeta);
    }
    if (data.containsKey('cached_at')) {
      context.handle(
        _cachedAtMeta,
        cachedAt.isAcceptableOrUnknown(data['cached_at']!, _cachedAtMeta),
      );
    }
    if (data.containsKey('pinned')) {
      context.handle(
        _pinnedMeta,
        pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {cacheKey};
  @override
  ApiCacheData map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ApiCacheData(
      cacheKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cache_key'],
      )!,
      data: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}data'],
      )!,
      cachedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}cached_at'],
      )!,
      pinned: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}pinned'],
      )!,
    );
  }

  @override
  $ApiCacheTable createAlias(String alias) {
    return $ApiCacheTable(attachedDatabase, alias);
  }
}

class ApiCacheData extends DataClass implements Insertable<ApiCacheData> {
  /// Composite key: serverId:endpoint (e.g., "abc123:/library/metadata/12345"
  /// for Plex, "abc123:/Users/.../Items/..." for Jellyfin)
  final String cacheKey;
  final String data;

  /// When the row was last written ([ApiCacheSingleton.put] stamps it on
  /// every store). Read by the fresh-cache-first playback metadata gate,
  /// [ApiCacheSingleton.getIfFresh].
  final DateTime cachedAt;

  /// Whether this item is pinned for offline access
  final bool pinned;
  const ApiCacheData({
    required this.cacheKey,
    required this.data,
    required this.cachedAt,
    required this.pinned,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['cache_key'] = Variable<String>(cacheKey);
    map['data'] = Variable<String>(data);
    map['cached_at'] = Variable<DateTime>(cachedAt);
    map['pinned'] = Variable<bool>(pinned);
    return map;
  }

  ApiCacheCompanion toCompanion(bool nullToAbsent) {
    return ApiCacheCompanion(
      cacheKey: Value(cacheKey),
      data: Value(data),
      cachedAt: Value(cachedAt),
      pinned: Value(pinned),
    );
  }

  factory ApiCacheData.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ApiCacheData(
      cacheKey: serializer.fromJson<String>(json['cacheKey']),
      data: serializer.fromJson<String>(json['data']),
      cachedAt: serializer.fromJson<DateTime>(json['cachedAt']),
      pinned: serializer.fromJson<bool>(json['pinned']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'cacheKey': serializer.toJson<String>(cacheKey),
      'data': serializer.toJson<String>(data),
      'cachedAt': serializer.toJson<DateTime>(cachedAt),
      'pinned': serializer.toJson<bool>(pinned),
    };
  }

  ApiCacheData copyWith({
    String? cacheKey,
    String? data,
    DateTime? cachedAt,
    bool? pinned,
  }) => ApiCacheData(
    cacheKey: cacheKey ?? this.cacheKey,
    data: data ?? this.data,
    cachedAt: cachedAt ?? this.cachedAt,
    pinned: pinned ?? this.pinned,
  );
  ApiCacheData copyWithCompanion(ApiCacheCompanion data) {
    return ApiCacheData(
      cacheKey: data.cacheKey.present ? data.cacheKey.value : this.cacheKey,
      data: data.data.present ? data.data.value : this.data,
      cachedAt: data.cachedAt.present ? data.cachedAt.value : this.cachedAt,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ApiCacheData(')
          ..write('cacheKey: $cacheKey, ')
          ..write('data: $data, ')
          ..write('cachedAt: $cachedAt, ')
          ..write('pinned: $pinned')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(cacheKey, data, cachedAt, pinned);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ApiCacheData &&
          other.cacheKey == this.cacheKey &&
          other.data == this.data &&
          other.cachedAt == this.cachedAt &&
          other.pinned == this.pinned);
}

class ApiCacheCompanion extends UpdateCompanion<ApiCacheData> {
  final Value<String> cacheKey;
  final Value<String> data;
  final Value<DateTime> cachedAt;
  final Value<bool> pinned;
  final Value<int> rowid;
  const ApiCacheCompanion({
    this.cacheKey = const Value.absent(),
    this.data = const Value.absent(),
    this.cachedAt = const Value.absent(),
    this.pinned = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ApiCacheCompanion.insert({
    required String cacheKey,
    required String data,
    this.cachedAt = const Value.absent(),
    this.pinned = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : cacheKey = Value(cacheKey),
       data = Value(data);
  static Insertable<ApiCacheData> custom({
    Expression<String>? cacheKey,
    Expression<String>? data,
    Expression<DateTime>? cachedAt,
    Expression<bool>? pinned,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (cacheKey != null) 'cache_key': cacheKey,
      if (data != null) 'data': data,
      if (cachedAt != null) 'cached_at': cachedAt,
      if (pinned != null) 'pinned': pinned,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ApiCacheCompanion copyWith({
    Value<String>? cacheKey,
    Value<String>? data,
    Value<DateTime>? cachedAt,
    Value<bool>? pinned,
    Value<int>? rowid,
  }) {
    return ApiCacheCompanion(
      cacheKey: cacheKey ?? this.cacheKey,
      data: data ?? this.data,
      cachedAt: cachedAt ?? this.cachedAt,
      pinned: pinned ?? this.pinned,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (cacheKey.present) {
      map['cache_key'] = Variable<String>(cacheKey.value);
    }
    if (data.present) {
      map['data'] = Variable<String>(data.value);
    }
    if (cachedAt.present) {
      map['cached_at'] = Variable<DateTime>(cachedAt.value);
    }
    if (pinned.present) {
      map['pinned'] = Variable<bool>(pinned.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ApiCacheCompanion(')
          ..write('cacheKey: $cacheKey, ')
          ..write('data: $data, ')
          ..write('cachedAt: $cachedAt, ')
          ..write('pinned: $pinned, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $OfflineWatchProgressTable extends OfflineWatchProgress
    with TableInfo<$OfflineWatchProgressTable, OfflineWatchProgressItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $OfflineWatchProgressTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _clientScopeIdMeta = const VerificationMeta(
    'clientScopeId',
  );
  @override
  late final GeneratedColumn<String> clientScopeId = GeneratedColumn<String>(
    'client_scope_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ratingKeyMeta = const VerificationMeta(
    'ratingKey',
  );
  @override
  late final GeneratedColumn<String> ratingKey = GeneratedColumn<String>(
    'rating_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _globalKeyMeta = const VerificationMeta(
    'globalKey',
  );
  @override
  late final GeneratedColumn<String> globalKey = GeneratedColumn<String>(
    'global_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _actionTypeMeta = const VerificationMeta(
    'actionType',
  );
  @override
  late final GeneratedColumn<String> actionType = GeneratedColumn<String>(
    'action_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _viewOffsetMeta = const VerificationMeta(
    'viewOffset',
  );
  @override
  late final GeneratedColumn<int> viewOffset = GeneratedColumn<int>(
    'view_offset',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMeta = const VerificationMeta(
    'duration',
  );
  @override
  late final GeneratedColumn<int> duration = GeneratedColumn<int>(
    'duration',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _shouldMarkWatchedMeta = const VerificationMeta(
    'shouldMarkWatched',
  );
  @override
  late final GeneratedColumn<bool> shouldMarkWatched = GeneratedColumn<bool>(
    'should_mark_watched',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("should_mark_watched" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _syncAttemptsMeta = const VerificationMeta(
    'syncAttempts',
  );
  @override
  late final GeneratedColumn<int> syncAttempts = GeneratedColumn<int>(
    'sync_attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileId,
    serverId,
    clientScopeId,
    ratingKey,
    globalKey,
    actionType,
    viewOffset,
    duration,
    shouldMarkWatched,
    createdAt,
    updatedAt,
    syncAttempts,
    lastError,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'offline_watch_progress';
  @override
  VerificationContext validateIntegrity(
    Insertable<OfflineWatchProgressItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('client_scope_id')) {
      context.handle(
        _clientScopeIdMeta,
        clientScopeId.isAcceptableOrUnknown(
          data['client_scope_id']!,
          _clientScopeIdMeta,
        ),
      );
    }
    if (data.containsKey('rating_key')) {
      context.handle(
        _ratingKeyMeta,
        ratingKey.isAcceptableOrUnknown(data['rating_key']!, _ratingKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_ratingKeyMeta);
    }
    if (data.containsKey('global_key')) {
      context.handle(
        _globalKeyMeta,
        globalKey.isAcceptableOrUnknown(data['global_key']!, _globalKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_globalKeyMeta);
    }
    if (data.containsKey('action_type')) {
      context.handle(
        _actionTypeMeta,
        actionType.isAcceptableOrUnknown(data['action_type']!, _actionTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_actionTypeMeta);
    }
    if (data.containsKey('view_offset')) {
      context.handle(
        _viewOffsetMeta,
        viewOffset.isAcceptableOrUnknown(data['view_offset']!, _viewOffsetMeta),
      );
    }
    if (data.containsKey('duration')) {
      context.handle(
        _durationMeta,
        duration.isAcceptableOrUnknown(data['duration']!, _durationMeta),
      );
    }
    if (data.containsKey('should_mark_watched')) {
      context.handle(
        _shouldMarkWatchedMeta,
        shouldMarkWatched.isAcceptableOrUnknown(
          data['should_mark_watched']!,
          _shouldMarkWatchedMeta,
        ),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('sync_attempts')) {
      context.handle(
        _syncAttemptsMeta,
        syncAttempts.isAcceptableOrUnknown(
          data['sync_attempts']!,
          _syncAttemptsMeta,
        ),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  OfflineWatchProgressItem map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return OfflineWatchProgressItem(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      ),
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      )!,
      clientScopeId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}client_scope_id'],
      ),
      ratingKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rating_key'],
      )!,
      globalKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}global_key'],
      )!,
      actionType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}action_type'],
      )!,
      viewOffset: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}view_offset'],
      ),
      duration: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration'],
      ),
      shouldMarkWatched: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}should_mark_watched'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      syncAttempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sync_attempts'],
      )!,
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
    );
  }

  @override
  $OfflineWatchProgressTable createAlias(String alias) {
    return $OfflineWatchProgressTable(attachedDatabase, alias);
  }
}

class OfflineWatchProgressItem extends DataClass
    implements Insertable<OfflineWatchProgressItem> {
  /// Auto-incrementing primary key
  final int id;

  /// Active Plezy profile that owns this queued action.
  final String? profileId;

  /// Server ID this media belongs to
  final String serverId;

  /// Optional user-scoped client/cache id for backends where [serverId] is
  /// shared by multiple users on the same server.
  final String? clientScopeId;

  /// Rating key of the media item
  final String ratingKey;

  /// Global key (serverId:ratingKey) for easy lookup
  final String globalKey;

  /// Type of action: 'progress', 'watched', 'unwatched'
  final String actionType;

  /// Current playback position in milliseconds (for 'progress' actions)
  final int? viewOffset;

  /// Duration of the media in milliseconds (for calculating percentage)
  final int? duration;

  /// Whether this item should be marked as watched (for progress sync)
  /// Auto-set to true when viewOffset >= 90% of duration
  final bool shouldMarkWatched;

  /// Timestamp when this action was recorded (milliseconds since epoch)
  final int createdAt;

  /// Timestamp when this action was last updated (for merging progress updates)
  final int updatedAt;

  /// Number of sync attempts (for retry logic)
  final int syncAttempts;

  /// Last sync error message
  final String? lastError;
  const OfflineWatchProgressItem({
    required this.id,
    this.profileId,
    required this.serverId,
    this.clientScopeId,
    required this.ratingKey,
    required this.globalKey,
    required this.actionType,
    this.viewOffset,
    this.duration,
    required this.shouldMarkWatched,
    required this.createdAt,
    required this.updatedAt,
    required this.syncAttempts,
    this.lastError,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    if (!nullToAbsent || profileId != null) {
      map['profile_id'] = Variable<String>(profileId);
    }
    map['server_id'] = Variable<String>(serverId);
    if (!nullToAbsent || clientScopeId != null) {
      map['client_scope_id'] = Variable<String>(clientScopeId);
    }
    map['rating_key'] = Variable<String>(ratingKey);
    map['global_key'] = Variable<String>(globalKey);
    map['action_type'] = Variable<String>(actionType);
    if (!nullToAbsent || viewOffset != null) {
      map['view_offset'] = Variable<int>(viewOffset);
    }
    if (!nullToAbsent || duration != null) {
      map['duration'] = Variable<int>(duration);
    }
    map['should_mark_watched'] = Variable<bool>(shouldMarkWatched);
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    map['sync_attempts'] = Variable<int>(syncAttempts);
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    return map;
  }

  OfflineWatchProgressCompanion toCompanion(bool nullToAbsent) {
    return OfflineWatchProgressCompanion(
      id: Value(id),
      profileId: profileId == null && nullToAbsent
          ? const Value.absent()
          : Value(profileId),
      serverId: Value(serverId),
      clientScopeId: clientScopeId == null && nullToAbsent
          ? const Value.absent()
          : Value(clientScopeId),
      ratingKey: Value(ratingKey),
      globalKey: Value(globalKey),
      actionType: Value(actionType),
      viewOffset: viewOffset == null && nullToAbsent
          ? const Value.absent()
          : Value(viewOffset),
      duration: duration == null && nullToAbsent
          ? const Value.absent()
          : Value(duration),
      shouldMarkWatched: Value(shouldMarkWatched),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      syncAttempts: Value(syncAttempts),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
    );
  }

  factory OfflineWatchProgressItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return OfflineWatchProgressItem(
      id: serializer.fromJson<int>(json['id']),
      profileId: serializer.fromJson<String?>(json['profileId']),
      serverId: serializer.fromJson<String>(json['serverId']),
      clientScopeId: serializer.fromJson<String?>(json['clientScopeId']),
      ratingKey: serializer.fromJson<String>(json['ratingKey']),
      globalKey: serializer.fromJson<String>(json['globalKey']),
      actionType: serializer.fromJson<String>(json['actionType']),
      viewOffset: serializer.fromJson<int?>(json['viewOffset']),
      duration: serializer.fromJson<int?>(json['duration']),
      shouldMarkWatched: serializer.fromJson<bool>(json['shouldMarkWatched']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      syncAttempts: serializer.fromJson<int>(json['syncAttempts']),
      lastError: serializer.fromJson<String?>(json['lastError']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'profileId': serializer.toJson<String?>(profileId),
      'serverId': serializer.toJson<String>(serverId),
      'clientScopeId': serializer.toJson<String?>(clientScopeId),
      'ratingKey': serializer.toJson<String>(ratingKey),
      'globalKey': serializer.toJson<String>(globalKey),
      'actionType': serializer.toJson<String>(actionType),
      'viewOffset': serializer.toJson<int?>(viewOffset),
      'duration': serializer.toJson<int?>(duration),
      'shouldMarkWatched': serializer.toJson<bool>(shouldMarkWatched),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'syncAttempts': serializer.toJson<int>(syncAttempts),
      'lastError': serializer.toJson<String?>(lastError),
    };
  }

  OfflineWatchProgressItem copyWith({
    int? id,
    Value<String?> profileId = const Value.absent(),
    String? serverId,
    Value<String?> clientScopeId = const Value.absent(),
    String? ratingKey,
    String? globalKey,
    String? actionType,
    Value<int?> viewOffset = const Value.absent(),
    Value<int?> duration = const Value.absent(),
    bool? shouldMarkWatched,
    int? createdAt,
    int? updatedAt,
    int? syncAttempts,
    Value<String?> lastError = const Value.absent(),
  }) => OfflineWatchProgressItem(
    id: id ?? this.id,
    profileId: profileId.present ? profileId.value : this.profileId,
    serverId: serverId ?? this.serverId,
    clientScopeId: clientScopeId.present
        ? clientScopeId.value
        : this.clientScopeId,
    ratingKey: ratingKey ?? this.ratingKey,
    globalKey: globalKey ?? this.globalKey,
    actionType: actionType ?? this.actionType,
    viewOffset: viewOffset.present ? viewOffset.value : this.viewOffset,
    duration: duration.present ? duration.value : this.duration,
    shouldMarkWatched: shouldMarkWatched ?? this.shouldMarkWatched,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    syncAttempts: syncAttempts ?? this.syncAttempts,
    lastError: lastError.present ? lastError.value : this.lastError,
  );
  OfflineWatchProgressItem copyWithCompanion(
    OfflineWatchProgressCompanion data,
  ) {
    return OfflineWatchProgressItem(
      id: data.id.present ? data.id.value : this.id,
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      clientScopeId: data.clientScopeId.present
          ? data.clientScopeId.value
          : this.clientScopeId,
      ratingKey: data.ratingKey.present ? data.ratingKey.value : this.ratingKey,
      globalKey: data.globalKey.present ? data.globalKey.value : this.globalKey,
      actionType: data.actionType.present
          ? data.actionType.value
          : this.actionType,
      viewOffset: data.viewOffset.present
          ? data.viewOffset.value
          : this.viewOffset,
      duration: data.duration.present ? data.duration.value : this.duration,
      shouldMarkWatched: data.shouldMarkWatched.present
          ? data.shouldMarkWatched.value
          : this.shouldMarkWatched,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      syncAttempts: data.syncAttempts.present
          ? data.syncAttempts.value
          : this.syncAttempts,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
    );
  }

  @override
  String toString() {
    return (StringBuffer('OfflineWatchProgressItem(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('serverId: $serverId, ')
          ..write('clientScopeId: $clientScopeId, ')
          ..write('ratingKey: $ratingKey, ')
          ..write('globalKey: $globalKey, ')
          ..write('actionType: $actionType, ')
          ..write('viewOffset: $viewOffset, ')
          ..write('duration: $duration, ')
          ..write('shouldMarkWatched: $shouldMarkWatched, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('syncAttempts: $syncAttempts, ')
          ..write('lastError: $lastError')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    profileId,
    serverId,
    clientScopeId,
    ratingKey,
    globalKey,
    actionType,
    viewOffset,
    duration,
    shouldMarkWatched,
    createdAt,
    updatedAt,
    syncAttempts,
    lastError,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is OfflineWatchProgressItem &&
          other.id == this.id &&
          other.profileId == this.profileId &&
          other.serverId == this.serverId &&
          other.clientScopeId == this.clientScopeId &&
          other.ratingKey == this.ratingKey &&
          other.globalKey == this.globalKey &&
          other.actionType == this.actionType &&
          other.viewOffset == this.viewOffset &&
          other.duration == this.duration &&
          other.shouldMarkWatched == this.shouldMarkWatched &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.syncAttempts == this.syncAttempts &&
          other.lastError == this.lastError);
}

class OfflineWatchProgressCompanion
    extends UpdateCompanion<OfflineWatchProgressItem> {
  final Value<int> id;
  final Value<String?> profileId;
  final Value<String> serverId;
  final Value<String?> clientScopeId;
  final Value<String> ratingKey;
  final Value<String> globalKey;
  final Value<String> actionType;
  final Value<int?> viewOffset;
  final Value<int?> duration;
  final Value<bool> shouldMarkWatched;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  final Value<int> syncAttempts;
  final Value<String?> lastError;
  const OfflineWatchProgressCompanion({
    this.id = const Value.absent(),
    this.profileId = const Value.absent(),
    this.serverId = const Value.absent(),
    this.clientScopeId = const Value.absent(),
    this.ratingKey = const Value.absent(),
    this.globalKey = const Value.absent(),
    this.actionType = const Value.absent(),
    this.viewOffset = const Value.absent(),
    this.duration = const Value.absent(),
    this.shouldMarkWatched = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.syncAttempts = const Value.absent(),
    this.lastError = const Value.absent(),
  });
  OfflineWatchProgressCompanion.insert({
    this.id = const Value.absent(),
    this.profileId = const Value.absent(),
    required String serverId,
    this.clientScopeId = const Value.absent(),
    required String ratingKey,
    required String globalKey,
    required String actionType,
    this.viewOffset = const Value.absent(),
    this.duration = const Value.absent(),
    this.shouldMarkWatched = const Value.absent(),
    required int createdAt,
    required int updatedAt,
    this.syncAttempts = const Value.absent(),
    this.lastError = const Value.absent(),
  }) : serverId = Value(serverId),
       ratingKey = Value(ratingKey),
       globalKey = Value(globalKey),
       actionType = Value(actionType),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<OfflineWatchProgressItem> custom({
    Expression<int>? id,
    Expression<String>? profileId,
    Expression<String>? serverId,
    Expression<String>? clientScopeId,
    Expression<String>? ratingKey,
    Expression<String>? globalKey,
    Expression<String>? actionType,
    Expression<int>? viewOffset,
    Expression<int>? duration,
    Expression<bool>? shouldMarkWatched,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
    Expression<int>? syncAttempts,
    Expression<String>? lastError,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileId != null) 'profile_id': profileId,
      if (serverId != null) 'server_id': serverId,
      if (clientScopeId != null) 'client_scope_id': clientScopeId,
      if (ratingKey != null) 'rating_key': ratingKey,
      if (globalKey != null) 'global_key': globalKey,
      if (actionType != null) 'action_type': actionType,
      if (viewOffset != null) 'view_offset': viewOffset,
      if (duration != null) 'duration': duration,
      if (shouldMarkWatched != null) 'should_mark_watched': shouldMarkWatched,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (syncAttempts != null) 'sync_attempts': syncAttempts,
      if (lastError != null) 'last_error': lastError,
    });
  }

  OfflineWatchProgressCompanion copyWith({
    Value<int>? id,
    Value<String?>? profileId,
    Value<String>? serverId,
    Value<String?>? clientScopeId,
    Value<String>? ratingKey,
    Value<String>? globalKey,
    Value<String>? actionType,
    Value<int?>? viewOffset,
    Value<int?>? duration,
    Value<bool>? shouldMarkWatched,
    Value<int>? createdAt,
    Value<int>? updatedAt,
    Value<int>? syncAttempts,
    Value<String?>? lastError,
  }) {
    return OfflineWatchProgressCompanion(
      id: id ?? this.id,
      profileId: profileId ?? this.profileId,
      serverId: serverId ?? this.serverId,
      clientScopeId: clientScopeId ?? this.clientScopeId,
      ratingKey: ratingKey ?? this.ratingKey,
      globalKey: globalKey ?? this.globalKey,
      actionType: actionType ?? this.actionType,
      viewOffset: viewOffset ?? this.viewOffset,
      duration: duration ?? this.duration,
      shouldMarkWatched: shouldMarkWatched ?? this.shouldMarkWatched,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      syncAttempts: syncAttempts ?? this.syncAttempts,
      lastError: lastError ?? this.lastError,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (clientScopeId.present) {
      map['client_scope_id'] = Variable<String>(clientScopeId.value);
    }
    if (ratingKey.present) {
      map['rating_key'] = Variable<String>(ratingKey.value);
    }
    if (globalKey.present) {
      map['global_key'] = Variable<String>(globalKey.value);
    }
    if (actionType.present) {
      map['action_type'] = Variable<String>(actionType.value);
    }
    if (viewOffset.present) {
      map['view_offset'] = Variable<int>(viewOffset.value);
    }
    if (duration.present) {
      map['duration'] = Variable<int>(duration.value);
    }
    if (shouldMarkWatched.present) {
      map['should_mark_watched'] = Variable<bool>(shouldMarkWatched.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (syncAttempts.present) {
      map['sync_attempts'] = Variable<int>(syncAttempts.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('OfflineWatchProgressCompanion(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('serverId: $serverId, ')
          ..write('clientScopeId: $clientScopeId, ')
          ..write('ratingKey: $ratingKey, ')
          ..write('globalKey: $globalKey, ')
          ..write('actionType: $actionType, ')
          ..write('viewOffset: $viewOffset, ')
          ..write('duration: $duration, ')
          ..write('shouldMarkWatched: $shouldMarkWatched, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('syncAttempts: $syncAttempts, ')
          ..write('lastError: $lastError')
          ..write(')'))
        .toString();
  }
}

class $SyncRulesTable extends SyncRules
    with TableInfo<$SyncRulesTable, SyncRuleItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncRulesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _ratingKeyMeta = const VerificationMeta(
    'ratingKey',
  );
  @override
  late final GeneratedColumn<String> ratingKey = GeneratedColumn<String>(
    'rating_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _globalKeyMeta = const VerificationMeta(
    'globalKey',
  );
  @override
  late final GeneratedColumn<String> globalKey = GeneratedColumn<String>(
    'global_key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  static const VerificationMeta _targetTypeMeta = const VerificationMeta(
    'targetType',
  );
  @override
  late final GeneratedColumn<String> targetType = GeneratedColumn<String>(
    'target_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _episodeCountMeta = const VerificationMeta(
    'episodeCount',
  );
  @override
  late final GeneratedColumn<int> episodeCount = GeneratedColumn<int>(
    'episode_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _enabledMeta = const VerificationMeta(
    'enabled',
  );
  @override
  late final GeneratedColumn<bool> enabled = GeneratedColumn<bool>(
    'enabled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("enabled" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastExecutedAtMeta = const VerificationMeta(
    'lastExecutedAt',
  );
  @override
  late final GeneratedColumn<int> lastExecutedAt = GeneratedColumn<int>(
    'last_executed_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _mediaIndexMeta = const VerificationMeta(
    'mediaIndex',
  );
  @override
  late final GeneratedColumn<int> mediaIndex = GeneratedColumn<int>(
    'media_index',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _downloadFilterMeta = const VerificationMeta(
    'downloadFilter',
  );
  @override
  late final GeneratedColumn<String> downloadFilter = GeneratedColumn<String>(
    'download_filter',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('unwatched'),
  );
  static const VerificationMeta _includeSpecialsMeta = const VerificationMeta(
    'includeSpecials',
  );
  @override
  late final GeneratedColumn<bool> includeSpecials = GeneratedColumn<bool>(
    'include_specials',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("include_specials" IN (0, 1))',
    ),
    defaultValue: const Constant(true),
  );
  static const VerificationMeta _downloadLinksInitializedMeta =
      const VerificationMeta('downloadLinksInitialized');
  @override
  late final GeneratedColumn<bool> downloadLinksInitialized =
      GeneratedColumn<bool>(
        'download_links_initialized',
        aliasedName,
        false,
        type: DriftSqlType.bool,
        requiredDuringInsert: false,
        defaultConstraints: GeneratedColumn.constraintIsAlways(
          'CHECK ("download_links_initialized" IN (0, 1))',
        ),
        defaultValue: const Constant(false),
      );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    profileId,
    serverId,
    ratingKey,
    globalKey,
    targetType,
    episodeCount,
    enabled,
    createdAt,
    lastExecutedAt,
    mediaIndex,
    downloadFilter,
    includeSpecials,
    downloadLinksInitialized,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_rules';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncRuleItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('rating_key')) {
      context.handle(
        _ratingKeyMeta,
        ratingKey.isAcceptableOrUnknown(data['rating_key']!, _ratingKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_ratingKeyMeta);
    }
    if (data.containsKey('global_key')) {
      context.handle(
        _globalKeyMeta,
        globalKey.isAcceptableOrUnknown(data['global_key']!, _globalKeyMeta),
      );
    } else if (isInserting) {
      context.missing(_globalKeyMeta);
    }
    if (data.containsKey('target_type')) {
      context.handle(
        _targetTypeMeta,
        targetType.isAcceptableOrUnknown(data['target_type']!, _targetTypeMeta),
      );
    } else if (isInserting) {
      context.missing(_targetTypeMeta);
    }
    if (data.containsKey('episode_count')) {
      context.handle(
        _episodeCountMeta,
        episodeCount.isAcceptableOrUnknown(
          data['episode_count']!,
          _episodeCountMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_episodeCountMeta);
    }
    if (data.containsKey('enabled')) {
      context.handle(
        _enabledMeta,
        enabled.isAcceptableOrUnknown(data['enabled']!, _enabledMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_executed_at')) {
      context.handle(
        _lastExecutedAtMeta,
        lastExecutedAt.isAcceptableOrUnknown(
          data['last_executed_at']!,
          _lastExecutedAtMeta,
        ),
      );
    }
    if (data.containsKey('media_index')) {
      context.handle(
        _mediaIndexMeta,
        mediaIndex.isAcceptableOrUnknown(data['media_index']!, _mediaIndexMeta),
      );
    }
    if (data.containsKey('download_filter')) {
      context.handle(
        _downloadFilterMeta,
        downloadFilter.isAcceptableOrUnknown(
          data['download_filter']!,
          _downloadFilterMeta,
        ),
      );
    }
    if (data.containsKey('include_specials')) {
      context.handle(
        _includeSpecialsMeta,
        includeSpecials.isAcceptableOrUnknown(
          data['include_specials']!,
          _includeSpecialsMeta,
        ),
      );
    }
    if (data.containsKey('download_links_initialized')) {
      context.handle(
        _downloadLinksInitializedMeta,
        downloadLinksInitialized.isAcceptableOrUnknown(
          data['download_links_initialized']!,
          _downloadLinksInitializedMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  SyncRuleItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncRuleItem(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      )!,
      ratingKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}rating_key'],
      )!,
      globalKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}global_key'],
      )!,
      targetType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}target_type'],
      )!,
      episodeCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}episode_count'],
      )!,
      enabled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}enabled'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      lastExecutedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_executed_at'],
      ),
      mediaIndex: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}media_index'],
      )!,
      downloadFilter: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}download_filter'],
      )!,
      includeSpecials: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}include_specials'],
      )!,
      downloadLinksInitialized: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}download_links_initialized'],
      )!,
    );
  }

  @override
  $SyncRulesTable createAlias(String alias) {
    return $SyncRulesTable(attachedDatabase, alias);
  }
}

class SyncRuleItem extends DataClass implements Insertable<SyncRuleItem> {
  final int id;
  final String profileId;
  final String serverId;
  final String ratingKey;
  final String globalKey;
  final String targetType;
  final int episodeCount;
  final bool enabled;
  final int createdAt;
  final int? lastExecutedAt;
  final int mediaIndex;
  final String downloadFilter;
  final bool includeSpecials;

  /// Gates collection/playlist backfill into [SyncRuleDownloads] before
  /// destructive cleanup. Show/season coverage is re-derived from
  /// [DownloadedMedia] ancestry at cleanup time regardless of this value.
  final bool downloadLinksInitialized;
  const SyncRuleItem({
    required this.id,
    required this.profileId,
    required this.serverId,
    required this.ratingKey,
    required this.globalKey,
    required this.targetType,
    required this.episodeCount,
    required this.enabled,
    required this.createdAt,
    this.lastExecutedAt,
    required this.mediaIndex,
    required this.downloadFilter,
    required this.includeSpecials,
    required this.downloadLinksInitialized,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['profile_id'] = Variable<String>(profileId);
    map['server_id'] = Variable<String>(serverId);
    map['rating_key'] = Variable<String>(ratingKey);
    map['global_key'] = Variable<String>(globalKey);
    map['target_type'] = Variable<String>(targetType);
    map['episode_count'] = Variable<int>(episodeCount);
    map['enabled'] = Variable<bool>(enabled);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || lastExecutedAt != null) {
      map['last_executed_at'] = Variable<int>(lastExecutedAt);
    }
    map['media_index'] = Variable<int>(mediaIndex);
    map['download_filter'] = Variable<String>(downloadFilter);
    map['include_specials'] = Variable<bool>(includeSpecials);
    map['download_links_initialized'] = Variable<bool>(
      downloadLinksInitialized,
    );
    return map;
  }

  SyncRulesCompanion toCompanion(bool nullToAbsent) {
    return SyncRulesCompanion(
      id: Value(id),
      profileId: Value(profileId),
      serverId: Value(serverId),
      ratingKey: Value(ratingKey),
      globalKey: Value(globalKey),
      targetType: Value(targetType),
      episodeCount: Value(episodeCount),
      enabled: Value(enabled),
      createdAt: Value(createdAt),
      lastExecutedAt: lastExecutedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastExecutedAt),
      mediaIndex: Value(mediaIndex),
      downloadFilter: Value(downloadFilter),
      includeSpecials: Value(includeSpecials),
      downloadLinksInitialized: Value(downloadLinksInitialized),
    );
  }

  factory SyncRuleItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncRuleItem(
      id: serializer.fromJson<int>(json['id']),
      profileId: serializer.fromJson<String>(json['profileId']),
      serverId: serializer.fromJson<String>(json['serverId']),
      ratingKey: serializer.fromJson<String>(json['ratingKey']),
      globalKey: serializer.fromJson<String>(json['globalKey']),
      targetType: serializer.fromJson<String>(json['targetType']),
      episodeCount: serializer.fromJson<int>(json['episodeCount']),
      enabled: serializer.fromJson<bool>(json['enabled']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      lastExecutedAt: serializer.fromJson<int?>(json['lastExecutedAt']),
      mediaIndex: serializer.fromJson<int>(json['mediaIndex']),
      downloadFilter: serializer.fromJson<String>(json['downloadFilter']),
      includeSpecials: serializer.fromJson<bool>(json['includeSpecials']),
      downloadLinksInitialized: serializer.fromJson<bool>(
        json['downloadLinksInitialized'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'profileId': serializer.toJson<String>(profileId),
      'serverId': serializer.toJson<String>(serverId),
      'ratingKey': serializer.toJson<String>(ratingKey),
      'globalKey': serializer.toJson<String>(globalKey),
      'targetType': serializer.toJson<String>(targetType),
      'episodeCount': serializer.toJson<int>(episodeCount),
      'enabled': serializer.toJson<bool>(enabled),
      'createdAt': serializer.toJson<int>(createdAt),
      'lastExecutedAt': serializer.toJson<int?>(lastExecutedAt),
      'mediaIndex': serializer.toJson<int>(mediaIndex),
      'downloadFilter': serializer.toJson<String>(downloadFilter),
      'includeSpecials': serializer.toJson<bool>(includeSpecials),
      'downloadLinksInitialized': serializer.toJson<bool>(
        downloadLinksInitialized,
      ),
    };
  }

  SyncRuleItem copyWith({
    int? id,
    String? profileId,
    String? serverId,
    String? ratingKey,
    String? globalKey,
    String? targetType,
    int? episodeCount,
    bool? enabled,
    int? createdAt,
    Value<int?> lastExecutedAt = const Value.absent(),
    int? mediaIndex,
    String? downloadFilter,
    bool? includeSpecials,
    bool? downloadLinksInitialized,
  }) => SyncRuleItem(
    id: id ?? this.id,
    profileId: profileId ?? this.profileId,
    serverId: serverId ?? this.serverId,
    ratingKey: ratingKey ?? this.ratingKey,
    globalKey: globalKey ?? this.globalKey,
    targetType: targetType ?? this.targetType,
    episodeCount: episodeCount ?? this.episodeCount,
    enabled: enabled ?? this.enabled,
    createdAt: createdAt ?? this.createdAt,
    lastExecutedAt: lastExecutedAt.present
        ? lastExecutedAt.value
        : this.lastExecutedAt,
    mediaIndex: mediaIndex ?? this.mediaIndex,
    downloadFilter: downloadFilter ?? this.downloadFilter,
    includeSpecials: includeSpecials ?? this.includeSpecials,
    downloadLinksInitialized:
        downloadLinksInitialized ?? this.downloadLinksInitialized,
  );
  SyncRuleItem copyWithCompanion(SyncRulesCompanion data) {
    return SyncRuleItem(
      id: data.id.present ? data.id.value : this.id,
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      ratingKey: data.ratingKey.present ? data.ratingKey.value : this.ratingKey,
      globalKey: data.globalKey.present ? data.globalKey.value : this.globalKey,
      targetType: data.targetType.present
          ? data.targetType.value
          : this.targetType,
      episodeCount: data.episodeCount.present
          ? data.episodeCount.value
          : this.episodeCount,
      enabled: data.enabled.present ? data.enabled.value : this.enabled,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastExecutedAt: data.lastExecutedAt.present
          ? data.lastExecutedAt.value
          : this.lastExecutedAt,
      mediaIndex: data.mediaIndex.present
          ? data.mediaIndex.value
          : this.mediaIndex,
      downloadFilter: data.downloadFilter.present
          ? data.downloadFilter.value
          : this.downloadFilter,
      includeSpecials: data.includeSpecials.present
          ? data.includeSpecials.value
          : this.includeSpecials,
      downloadLinksInitialized: data.downloadLinksInitialized.present
          ? data.downloadLinksInitialized.value
          : this.downloadLinksInitialized,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncRuleItem(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('serverId: $serverId, ')
          ..write('ratingKey: $ratingKey, ')
          ..write('globalKey: $globalKey, ')
          ..write('targetType: $targetType, ')
          ..write('episodeCount: $episodeCount, ')
          ..write('enabled: $enabled, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastExecutedAt: $lastExecutedAt, ')
          ..write('mediaIndex: $mediaIndex, ')
          ..write('downloadFilter: $downloadFilter, ')
          ..write('includeSpecials: $includeSpecials, ')
          ..write('downloadLinksInitialized: $downloadLinksInitialized')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    profileId,
    serverId,
    ratingKey,
    globalKey,
    targetType,
    episodeCount,
    enabled,
    createdAt,
    lastExecutedAt,
    mediaIndex,
    downloadFilter,
    includeSpecials,
    downloadLinksInitialized,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncRuleItem &&
          other.id == this.id &&
          other.profileId == this.profileId &&
          other.serverId == this.serverId &&
          other.ratingKey == this.ratingKey &&
          other.globalKey == this.globalKey &&
          other.targetType == this.targetType &&
          other.episodeCount == this.episodeCount &&
          other.enabled == this.enabled &&
          other.createdAt == this.createdAt &&
          other.lastExecutedAt == this.lastExecutedAt &&
          other.mediaIndex == this.mediaIndex &&
          other.downloadFilter == this.downloadFilter &&
          other.includeSpecials == this.includeSpecials &&
          other.downloadLinksInitialized == this.downloadLinksInitialized);
}

class SyncRulesCompanion extends UpdateCompanion<SyncRuleItem> {
  final Value<int> id;
  final Value<String> profileId;
  final Value<String> serverId;
  final Value<String> ratingKey;
  final Value<String> globalKey;
  final Value<String> targetType;
  final Value<int> episodeCount;
  final Value<bool> enabled;
  final Value<int> createdAt;
  final Value<int?> lastExecutedAt;
  final Value<int> mediaIndex;
  final Value<String> downloadFilter;
  final Value<bool> includeSpecials;
  final Value<bool> downloadLinksInitialized;
  const SyncRulesCompanion({
    this.id = const Value.absent(),
    this.profileId = const Value.absent(),
    this.serverId = const Value.absent(),
    this.ratingKey = const Value.absent(),
    this.globalKey = const Value.absent(),
    this.targetType = const Value.absent(),
    this.episodeCount = const Value.absent(),
    this.enabled = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastExecutedAt = const Value.absent(),
    this.mediaIndex = const Value.absent(),
    this.downloadFilter = const Value.absent(),
    this.includeSpecials = const Value.absent(),
    this.downloadLinksInitialized = const Value.absent(),
  });
  SyncRulesCompanion.insert({
    this.id = const Value.absent(),
    this.profileId = const Value.absent(),
    required String serverId,
    required String ratingKey,
    required String globalKey,
    required String targetType,
    required int episodeCount,
    this.enabled = const Value.absent(),
    required int createdAt,
    this.lastExecutedAt = const Value.absent(),
    this.mediaIndex = const Value.absent(),
    this.downloadFilter = const Value.absent(),
    this.includeSpecials = const Value.absent(),
    this.downloadLinksInitialized = const Value.absent(),
  }) : serverId = Value(serverId),
       ratingKey = Value(ratingKey),
       globalKey = Value(globalKey),
       targetType = Value(targetType),
       episodeCount = Value(episodeCount),
       createdAt = Value(createdAt);
  static Insertable<SyncRuleItem> custom({
    Expression<int>? id,
    Expression<String>? profileId,
    Expression<String>? serverId,
    Expression<String>? ratingKey,
    Expression<String>? globalKey,
    Expression<String>? targetType,
    Expression<int>? episodeCount,
    Expression<bool>? enabled,
    Expression<int>? createdAt,
    Expression<int>? lastExecutedAt,
    Expression<int>? mediaIndex,
    Expression<String>? downloadFilter,
    Expression<bool>? includeSpecials,
    Expression<bool>? downloadLinksInitialized,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (profileId != null) 'profile_id': profileId,
      if (serverId != null) 'server_id': serverId,
      if (ratingKey != null) 'rating_key': ratingKey,
      if (globalKey != null) 'global_key': globalKey,
      if (targetType != null) 'target_type': targetType,
      if (episodeCount != null) 'episode_count': episodeCount,
      if (enabled != null) 'enabled': enabled,
      if (createdAt != null) 'created_at': createdAt,
      if (lastExecutedAt != null) 'last_executed_at': lastExecutedAt,
      if (mediaIndex != null) 'media_index': mediaIndex,
      if (downloadFilter != null) 'download_filter': downloadFilter,
      if (includeSpecials != null) 'include_specials': includeSpecials,
      if (downloadLinksInitialized != null)
        'download_links_initialized': downloadLinksInitialized,
    });
  }

  SyncRulesCompanion copyWith({
    Value<int>? id,
    Value<String>? profileId,
    Value<String>? serverId,
    Value<String>? ratingKey,
    Value<String>? globalKey,
    Value<String>? targetType,
    Value<int>? episodeCount,
    Value<bool>? enabled,
    Value<int>? createdAt,
    Value<int?>? lastExecutedAt,
    Value<int>? mediaIndex,
    Value<String>? downloadFilter,
    Value<bool>? includeSpecials,
    Value<bool>? downloadLinksInitialized,
  }) {
    return SyncRulesCompanion(
      id: id ?? this.id,
      profileId: profileId ?? this.profileId,
      serverId: serverId ?? this.serverId,
      ratingKey: ratingKey ?? this.ratingKey,
      globalKey: globalKey ?? this.globalKey,
      targetType: targetType ?? this.targetType,
      episodeCount: episodeCount ?? this.episodeCount,
      enabled: enabled ?? this.enabled,
      createdAt: createdAt ?? this.createdAt,
      lastExecutedAt: lastExecutedAt ?? this.lastExecutedAt,
      mediaIndex: mediaIndex ?? this.mediaIndex,
      downloadFilter: downloadFilter ?? this.downloadFilter,
      includeSpecials: includeSpecials ?? this.includeSpecials,
      downloadLinksInitialized:
          downloadLinksInitialized ?? this.downloadLinksInitialized,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (ratingKey.present) {
      map['rating_key'] = Variable<String>(ratingKey.value);
    }
    if (globalKey.present) {
      map['global_key'] = Variable<String>(globalKey.value);
    }
    if (targetType.present) {
      map['target_type'] = Variable<String>(targetType.value);
    }
    if (episodeCount.present) {
      map['episode_count'] = Variable<int>(episodeCount.value);
    }
    if (enabled.present) {
      map['enabled'] = Variable<bool>(enabled.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (lastExecutedAt.present) {
      map['last_executed_at'] = Variable<int>(lastExecutedAt.value);
    }
    if (mediaIndex.present) {
      map['media_index'] = Variable<int>(mediaIndex.value);
    }
    if (downloadFilter.present) {
      map['download_filter'] = Variable<String>(downloadFilter.value);
    }
    if (includeSpecials.present) {
      map['include_specials'] = Variable<bool>(includeSpecials.value);
    }
    if (downloadLinksInitialized.present) {
      map['download_links_initialized'] = Variable<bool>(
        downloadLinksInitialized.value,
      );
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncRulesCompanion(')
          ..write('id: $id, ')
          ..write('profileId: $profileId, ')
          ..write('serverId: $serverId, ')
          ..write('ratingKey: $ratingKey, ')
          ..write('globalKey: $globalKey, ')
          ..write('targetType: $targetType, ')
          ..write('episodeCount: $episodeCount, ')
          ..write('enabled: $enabled, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastExecutedAt: $lastExecutedAt, ')
          ..write('mediaIndex: $mediaIndex, ')
          ..write('downloadFilter: $downloadFilter, ')
          ..write('includeSpecials: $includeSpecials, ')
          ..write('downloadLinksInitialized: $downloadLinksInitialized')
          ..write(')'))
        .toString();
  }
}

class $SyncRuleDownloadsTable extends SyncRuleDownloads
    with TableInfo<$SyncRuleDownloadsTable, SyncRuleDownloadItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $SyncRuleDownloadsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _syncRuleIdMeta = const VerificationMeta(
    'syncRuleId',
  );
  @override
  late final GeneratedColumn<int> syncRuleId = GeneratedColumn<int>(
    'sync_rule_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES sync_rules (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _downloadGlobalKeyMeta = const VerificationMeta(
    'downloadGlobalKey',
  );
  @override
  late final GeneratedColumn<String> downloadGlobalKey =
      GeneratedColumn<String>(
        'download_global_key',
        aliasedName,
        false,
        type: DriftSqlType.string,
        requiredDuringInsert: true,
      );
  @override
  List<GeneratedColumn> get $columns => [
    syncRuleId,
    profileId,
    downloadGlobalKey,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'sync_rule_downloads';
  @override
  VerificationContext validateIntegrity(
    Insertable<SyncRuleDownloadItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('sync_rule_id')) {
      context.handle(
        _syncRuleIdMeta,
        syncRuleId.isAcceptableOrUnknown(
          data['sync_rule_id']!,
          _syncRuleIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_syncRuleIdMeta);
    }
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('download_global_key')) {
      context.handle(
        _downloadGlobalKeyMeta,
        downloadGlobalKey.isAcceptableOrUnknown(
          data['download_global_key']!,
          _downloadGlobalKeyMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_downloadGlobalKeyMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {syncRuleId, downloadGlobalKey};
  @override
  SyncRuleDownloadItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return SyncRuleDownloadItem(
      syncRuleId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sync_rule_id'],
      )!,
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      downloadGlobalKey: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}download_global_key'],
      )!,
    );
  }

  @override
  $SyncRuleDownloadsTable createAlias(String alias) {
    return $SyncRuleDownloadsTable(attachedDatabase, alias);
  }
}

class SyncRuleDownloadItem extends DataClass
    implements Insertable<SyncRuleDownloadItem> {
  final int syncRuleId;
  final String profileId;
  final String downloadGlobalKey;
  const SyncRuleDownloadItem({
    required this.syncRuleId,
    required this.profileId,
    required this.downloadGlobalKey,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['sync_rule_id'] = Variable<int>(syncRuleId);
    map['profile_id'] = Variable<String>(profileId);
    map['download_global_key'] = Variable<String>(downloadGlobalKey);
    return map;
  }

  SyncRuleDownloadsCompanion toCompanion(bool nullToAbsent) {
    return SyncRuleDownloadsCompanion(
      syncRuleId: Value(syncRuleId),
      profileId: Value(profileId),
      downloadGlobalKey: Value(downloadGlobalKey),
    );
  }

  factory SyncRuleDownloadItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return SyncRuleDownloadItem(
      syncRuleId: serializer.fromJson<int>(json['syncRuleId']),
      profileId: serializer.fromJson<String>(json['profileId']),
      downloadGlobalKey: serializer.fromJson<String>(json['downloadGlobalKey']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'syncRuleId': serializer.toJson<int>(syncRuleId),
      'profileId': serializer.toJson<String>(profileId),
      'downloadGlobalKey': serializer.toJson<String>(downloadGlobalKey),
    };
  }

  SyncRuleDownloadItem copyWith({
    int? syncRuleId,
    String? profileId,
    String? downloadGlobalKey,
  }) => SyncRuleDownloadItem(
    syncRuleId: syncRuleId ?? this.syncRuleId,
    profileId: profileId ?? this.profileId,
    downloadGlobalKey: downloadGlobalKey ?? this.downloadGlobalKey,
  );
  SyncRuleDownloadItem copyWithCompanion(SyncRuleDownloadsCompanion data) {
    return SyncRuleDownloadItem(
      syncRuleId: data.syncRuleId.present
          ? data.syncRuleId.value
          : this.syncRuleId,
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      downloadGlobalKey: data.downloadGlobalKey.present
          ? data.downloadGlobalKey.value
          : this.downloadGlobalKey,
    );
  }

  @override
  String toString() {
    return (StringBuffer('SyncRuleDownloadItem(')
          ..write('syncRuleId: $syncRuleId, ')
          ..write('profileId: $profileId, ')
          ..write('downloadGlobalKey: $downloadGlobalKey')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(syncRuleId, profileId, downloadGlobalKey);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is SyncRuleDownloadItem &&
          other.syncRuleId == this.syncRuleId &&
          other.profileId == this.profileId &&
          other.downloadGlobalKey == this.downloadGlobalKey);
}

class SyncRuleDownloadsCompanion extends UpdateCompanion<SyncRuleDownloadItem> {
  final Value<int> syncRuleId;
  final Value<String> profileId;
  final Value<String> downloadGlobalKey;
  final Value<int> rowid;
  const SyncRuleDownloadsCompanion({
    this.syncRuleId = const Value.absent(),
    this.profileId = const Value.absent(),
    this.downloadGlobalKey = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  SyncRuleDownloadsCompanion.insert({
    required int syncRuleId,
    required String profileId,
    required String downloadGlobalKey,
    this.rowid = const Value.absent(),
  }) : syncRuleId = Value(syncRuleId),
       profileId = Value(profileId),
       downloadGlobalKey = Value(downloadGlobalKey);
  static Insertable<SyncRuleDownloadItem> custom({
    Expression<int>? syncRuleId,
    Expression<String>? profileId,
    Expression<String>? downloadGlobalKey,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (syncRuleId != null) 'sync_rule_id': syncRuleId,
      if (profileId != null) 'profile_id': profileId,
      if (downloadGlobalKey != null) 'download_global_key': downloadGlobalKey,
      if (rowid != null) 'rowid': rowid,
    });
  }

  SyncRuleDownloadsCompanion copyWith({
    Value<int>? syncRuleId,
    Value<String>? profileId,
    Value<String>? downloadGlobalKey,
    Value<int>? rowid,
  }) {
    return SyncRuleDownloadsCompanion(
      syncRuleId: syncRuleId ?? this.syncRuleId,
      profileId: profileId ?? this.profileId,
      downloadGlobalKey: downloadGlobalKey ?? this.downloadGlobalKey,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (syncRuleId.present) {
      map['sync_rule_id'] = Variable<int>(syncRuleId.value);
    }
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (downloadGlobalKey.present) {
      map['download_global_key'] = Variable<String>(downloadGlobalKey.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('SyncRuleDownloadsCompanion(')
          ..write('syncRuleId: $syncRuleId, ')
          ..write('profileId: $profileId, ')
          ..write('downloadGlobalKey: $downloadGlobalKey, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DownloadCollectionsTable extends DownloadCollections
    with TableInfo<$DownloadCollectionsTable, DownloadCollectionItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadCollectionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _collectionIdMeta = const VerificationMeta(
    'collectionId',
  );
  @override
  late final GeneratedColumn<String> collectionId = GeneratedColumn<String>(
    'collection_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _memberIdsMeta = const VerificationMeta(
    'memberIds',
  );
  @override
  late final GeneratedColumn<String> memberIds = GeneratedColumn<String>(
    'member_ids',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    serverId,
    collectionId,
    memberIds,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'download_collections';
  @override
  VerificationContext validateIntegrity(
    Insertable<DownloadCollectionItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('collection_id')) {
      context.handle(
        _collectionIdMeta,
        collectionId.isAcceptableOrUnknown(
          data['collection_id']!,
          _collectionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_collectionIdMeta);
    }
    if (data.containsKey('member_ids')) {
      context.handle(
        _memberIdsMeta,
        memberIds.isAcceptableOrUnknown(data['member_ids']!, _memberIdsMeta),
      );
    } else if (isInserting) {
      context.missing(_memberIdsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId, serverId, collectionId};
  @override
  DownloadCollectionItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadCollectionItem(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      )!,
      collectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}collection_id'],
      )!,
      memberIds: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}member_ids'],
      )!,
    );
  }

  @override
  $DownloadCollectionsTable createAlias(String alias) {
    return $DownloadCollectionsTable(attachedDatabase, alias);
  }
}

class DownloadCollectionItem extends DataClass
    implements Insertable<DownloadCollectionItem> {
  final String profileId;
  final String serverId;
  final String collectionId;
  final String memberIds;
  const DownloadCollectionItem({
    required this.profileId,
    required this.serverId,
    required this.collectionId,
    required this.memberIds,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['server_id'] = Variable<String>(serverId);
    map['collection_id'] = Variable<String>(collectionId);
    map['member_ids'] = Variable<String>(memberIds);
    return map;
  }

  DownloadCollectionsCompanion toCompanion(bool nullToAbsent) {
    return DownloadCollectionsCompanion(
      profileId: Value(profileId),
      serverId: Value(serverId),
      collectionId: Value(collectionId),
      memberIds: Value(memberIds),
    );
  }

  factory DownloadCollectionItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadCollectionItem(
      profileId: serializer.fromJson<String>(json['profileId']),
      serverId: serializer.fromJson<String>(json['serverId']),
      collectionId: serializer.fromJson<String>(json['collectionId']),
      memberIds: serializer.fromJson<String>(json['memberIds']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'serverId': serializer.toJson<String>(serverId),
      'collectionId': serializer.toJson<String>(collectionId),
      'memberIds': serializer.toJson<String>(memberIds),
    };
  }

  DownloadCollectionItem copyWith({
    String? profileId,
    String? serverId,
    String? collectionId,
    String? memberIds,
  }) => DownloadCollectionItem(
    profileId: profileId ?? this.profileId,
    serverId: serverId ?? this.serverId,
    collectionId: collectionId ?? this.collectionId,
    memberIds: memberIds ?? this.memberIds,
  );
  DownloadCollectionItem copyWithCompanion(DownloadCollectionsCompanion data) {
    return DownloadCollectionItem(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      collectionId: data.collectionId.present
          ? data.collectionId.value
          : this.collectionId,
      memberIds: data.memberIds.present ? data.memberIds.value : this.memberIds,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadCollectionItem(')
          ..write('profileId: $profileId, ')
          ..write('serverId: $serverId, ')
          ..write('collectionId: $collectionId, ')
          ..write('memberIds: $memberIds')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(profileId, serverId, collectionId, memberIds);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadCollectionItem &&
          other.profileId == this.profileId &&
          other.serverId == this.serverId &&
          other.collectionId == this.collectionId &&
          other.memberIds == this.memberIds);
}

class DownloadCollectionsCompanion
    extends UpdateCompanion<DownloadCollectionItem> {
  final Value<String> profileId;
  final Value<String> serverId;
  final Value<String> collectionId;
  final Value<String> memberIds;
  final Value<int> rowid;
  const DownloadCollectionsCompanion({
    this.profileId = const Value.absent(),
    this.serverId = const Value.absent(),
    this.collectionId = const Value.absent(),
    this.memberIds = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DownloadCollectionsCompanion.insert({
    required String profileId,
    required String serverId,
    required String collectionId,
    required String memberIds,
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       serverId = Value(serverId),
       collectionId = Value(collectionId),
       memberIds = Value(memberIds);
  static Insertable<DownloadCollectionItem> custom({
    Expression<String>? profileId,
    Expression<String>? serverId,
    Expression<String>? collectionId,
    Expression<String>? memberIds,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (serverId != null) 'server_id': serverId,
      if (collectionId != null) 'collection_id': collectionId,
      if (memberIds != null) 'member_ids': memberIds,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DownloadCollectionsCompanion copyWith({
    Value<String>? profileId,
    Value<String>? serverId,
    Value<String>? collectionId,
    Value<String>? memberIds,
    Value<int>? rowid,
  }) {
    return DownloadCollectionsCompanion(
      profileId: profileId ?? this.profileId,
      serverId: serverId ?? this.serverId,
      collectionId: collectionId ?? this.collectionId,
      memberIds: memberIds ?? this.memberIds,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (collectionId.present) {
      map['collection_id'] = Variable<String>(collectionId.value);
    }
    if (memberIds.present) {
      map['member_ids'] = Variable<String>(memberIds.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadCollectionsCompanion(')
          ..write('profileId: $profileId, ')
          ..write('serverId: $serverId, ')
          ..write('collectionId: $collectionId, ')
          ..write('memberIds: $memberIds, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $DownloadCollectionSyncsTable extends DownloadCollectionSyncs
    with TableInfo<$DownloadCollectionSyncsTable, DownloadCollectionSyncItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $DownloadCollectionSyncsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _serverIdMeta = const VerificationMeta(
    'serverId',
  );
  @override
  late final GeneratedColumn<String> serverId = GeneratedColumn<String>(
    'server_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _syncedAtMeta = const VerificationMeta(
    'syncedAt',
  );
  @override
  late final GeneratedColumn<int> syncedAt = GeneratedColumn<int>(
    'synced_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _checkedIdsMeta = const VerificationMeta(
    'checkedIds',
  );
  @override
  late final GeneratedColumn<String> checkedIds = GeneratedColumn<String>(
    'checked_ids',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    serverId,
    syncedAt,
    checkedIds,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'download_collection_syncs';
  @override
  VerificationContext validateIntegrity(
    Insertable<DownloadCollectionSyncItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('server_id')) {
      context.handle(
        _serverIdMeta,
        serverId.isAcceptableOrUnknown(data['server_id']!, _serverIdMeta),
      );
    } else if (isInserting) {
      context.missing(_serverIdMeta);
    }
    if (data.containsKey('synced_at')) {
      context.handle(
        _syncedAtMeta,
        syncedAt.isAcceptableOrUnknown(data['synced_at']!, _syncedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_syncedAtMeta);
    }
    if (data.containsKey('checked_ids')) {
      context.handle(
        _checkedIdsMeta,
        checkedIds.isAcceptableOrUnknown(data['checked_ids']!, _checkedIdsMeta),
      );
    } else if (isInserting) {
      context.missing(_checkedIdsMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId, serverId};
  @override
  DownloadCollectionSyncItem map(
    Map<String, dynamic> data, {
    String? tablePrefix,
  }) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return DownloadCollectionSyncItem(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      serverId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_id'],
      )!,
      syncedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}synced_at'],
      )!,
      checkedIds: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}checked_ids'],
      )!,
    );
  }

  @override
  $DownloadCollectionSyncsTable createAlias(String alias) {
    return $DownloadCollectionSyncsTable(attachedDatabase, alias);
  }
}

class DownloadCollectionSyncItem extends DataClass
    implements Insertable<DownloadCollectionSyncItem> {
  final String profileId;
  final String serverId;
  final int syncedAt;
  final String checkedIds;
  const DownloadCollectionSyncItem({
    required this.profileId,
    required this.serverId,
    required this.syncedAt,
    required this.checkedIds,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['server_id'] = Variable<String>(serverId);
    map['synced_at'] = Variable<int>(syncedAt);
    map['checked_ids'] = Variable<String>(checkedIds);
    return map;
  }

  DownloadCollectionSyncsCompanion toCompanion(bool nullToAbsent) {
    return DownloadCollectionSyncsCompanion(
      profileId: Value(profileId),
      serverId: Value(serverId),
      syncedAt: Value(syncedAt),
      checkedIds: Value(checkedIds),
    );
  }

  factory DownloadCollectionSyncItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return DownloadCollectionSyncItem(
      profileId: serializer.fromJson<String>(json['profileId']),
      serverId: serializer.fromJson<String>(json['serverId']),
      syncedAt: serializer.fromJson<int>(json['syncedAt']),
      checkedIds: serializer.fromJson<String>(json['checkedIds']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'serverId': serializer.toJson<String>(serverId),
      'syncedAt': serializer.toJson<int>(syncedAt),
      'checkedIds': serializer.toJson<String>(checkedIds),
    };
  }

  DownloadCollectionSyncItem copyWith({
    String? profileId,
    String? serverId,
    int? syncedAt,
    String? checkedIds,
  }) => DownloadCollectionSyncItem(
    profileId: profileId ?? this.profileId,
    serverId: serverId ?? this.serverId,
    syncedAt: syncedAt ?? this.syncedAt,
    checkedIds: checkedIds ?? this.checkedIds,
  );
  DownloadCollectionSyncItem copyWithCompanion(
    DownloadCollectionSyncsCompanion data,
  ) {
    return DownloadCollectionSyncItem(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      serverId: data.serverId.present ? data.serverId.value : this.serverId,
      syncedAt: data.syncedAt.present ? data.syncedAt.value : this.syncedAt,
      checkedIds: data.checkedIds.present
          ? data.checkedIds.value
          : this.checkedIds,
    );
  }

  @override
  String toString() {
    return (StringBuffer('DownloadCollectionSyncItem(')
          ..write('profileId: $profileId, ')
          ..write('serverId: $serverId, ')
          ..write('syncedAt: $syncedAt, ')
          ..write('checkedIds: $checkedIds')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(profileId, serverId, syncedAt, checkedIds);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is DownloadCollectionSyncItem &&
          other.profileId == this.profileId &&
          other.serverId == this.serverId &&
          other.syncedAt == this.syncedAt &&
          other.checkedIds == this.checkedIds);
}

class DownloadCollectionSyncsCompanion
    extends UpdateCompanion<DownloadCollectionSyncItem> {
  final Value<String> profileId;
  final Value<String> serverId;
  final Value<int> syncedAt;
  final Value<String> checkedIds;
  final Value<int> rowid;
  const DownloadCollectionSyncsCompanion({
    this.profileId = const Value.absent(),
    this.serverId = const Value.absent(),
    this.syncedAt = const Value.absent(),
    this.checkedIds = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  DownloadCollectionSyncsCompanion.insert({
    required String profileId,
    required String serverId,
    required int syncedAt,
    required String checkedIds,
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       serverId = Value(serverId),
       syncedAt = Value(syncedAt),
       checkedIds = Value(checkedIds);
  static Insertable<DownloadCollectionSyncItem> custom({
    Expression<String>? profileId,
    Expression<String>? serverId,
    Expression<int>? syncedAt,
    Expression<String>? checkedIds,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (serverId != null) 'server_id': serverId,
      if (syncedAt != null) 'synced_at': syncedAt,
      if (checkedIds != null) 'checked_ids': checkedIds,
      if (rowid != null) 'rowid': rowid,
    });
  }

  DownloadCollectionSyncsCompanion copyWith({
    Value<String>? profileId,
    Value<String>? serverId,
    Value<int>? syncedAt,
    Value<String>? checkedIds,
    Value<int>? rowid,
  }) {
    return DownloadCollectionSyncsCompanion(
      profileId: profileId ?? this.profileId,
      serverId: serverId ?? this.serverId,
      syncedAt: syncedAt ?? this.syncedAt,
      checkedIds: checkedIds ?? this.checkedIds,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (serverId.present) {
      map['server_id'] = Variable<String>(serverId.value);
    }
    if (syncedAt.present) {
      map['synced_at'] = Variable<int>(syncedAt.value);
    }
    if (checkedIds.present) {
      map['checked_ids'] = Variable<String>(checkedIds.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('DownloadCollectionSyncsCompanion(')
          ..write('profileId: $profileId, ')
          ..write('serverId: $serverId, ')
          ..write('syncedAt: $syncedAt, ')
          ..write('checkedIds: $checkedIds, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ConnectionsTable extends Connections
    with TableInfo<$ConnectionsTable, ConnectionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConnectionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _configJsonMeta = const VerificationMeta(
    'configJson',
  );
  @override
  late final GeneratedColumn<String> configJson = GeneratedColumn<String>(
    'config_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastAuthenticatedAtMeta =
      const VerificationMeta('lastAuthenticatedAt');
  @override
  late final GeneratedColumn<int> lastAuthenticatedAt = GeneratedColumn<int>(
    'last_authenticated_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    displayName,
    configJson,
    createdAt,
    lastAuthenticatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'connections';
  @override
  VerificationContext validateIntegrity(
    Insertable<ConnectionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('config_json')) {
      context.handle(
        _configJsonMeta,
        configJson.isAcceptableOrUnknown(data['config_json']!, _configJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_configJsonMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_authenticated_at')) {
      context.handle(
        _lastAuthenticatedAtMeta,
        lastAuthenticatedAt.isAcceptableOrUnknown(
          data['last_authenticated_at']!,
          _lastAuthenticatedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConnectionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConnectionRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      configJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}config_json'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      lastAuthenticatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_authenticated_at'],
      ),
    );
  }

  @override
  $ConnectionsTable createAlias(String alias) {
    return $ConnectionsTable(attachedDatabase, alias);
  }
}

class ConnectionRow extends DataClass implements Insertable<ConnectionRow> {
  /// Stable identifier for the connection. For Plex it's a generated UUID
  /// (one per account); for Jellyfin it's the server's machineId.
  final String id;

  /// Backend kind: `'plex'`, `'jellyfin'`, or `'emby'`.
  final String kind;

  /// User-visible label (account email, server name).
  final String displayName;

  /// Backend-specific config payload (token, baseUrl, profile id, …).
  final String configJson;

  /// Timestamp this connection was added (milliseconds since epoch).
  final int createdAt;

  /// Timestamp of the most-recent successful auth refresh (milliseconds
  /// since epoch). Null until the first successful auth.
  final int? lastAuthenticatedAt;
  const ConnectionRow({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.configJson,
    required this.createdAt,
    this.lastAuthenticatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    map['display_name'] = Variable<String>(displayName);
    map['config_json'] = Variable<String>(configJson);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || lastAuthenticatedAt != null) {
      map['last_authenticated_at'] = Variable<int>(lastAuthenticatedAt);
    }
    return map;
  }

  ConnectionsCompanion toCompanion(bool nullToAbsent) {
    return ConnectionsCompanion(
      id: Value(id),
      kind: Value(kind),
      displayName: Value(displayName),
      configJson: Value(configJson),
      createdAt: Value(createdAt),
      lastAuthenticatedAt: lastAuthenticatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastAuthenticatedAt),
    );
  }

  factory ConnectionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConnectionRow(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      displayName: serializer.fromJson<String>(json['displayName']),
      configJson: serializer.fromJson<String>(json['configJson']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      lastAuthenticatedAt: serializer.fromJson<int?>(
        json['lastAuthenticatedAt'],
      ),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'displayName': serializer.toJson<String>(displayName),
      'configJson': serializer.toJson<String>(configJson),
      'createdAt': serializer.toJson<int>(createdAt),
      'lastAuthenticatedAt': serializer.toJson<int?>(lastAuthenticatedAt),
    };
  }

  ConnectionRow copyWith({
    String? id,
    String? kind,
    String? displayName,
    String? configJson,
    int? createdAt,
    Value<int?> lastAuthenticatedAt = const Value.absent(),
  }) => ConnectionRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    displayName: displayName ?? this.displayName,
    configJson: configJson ?? this.configJson,
    createdAt: createdAt ?? this.createdAt,
    lastAuthenticatedAt: lastAuthenticatedAt.present
        ? lastAuthenticatedAt.value
        : this.lastAuthenticatedAt,
  );
  ConnectionRow copyWithCompanion(ConnectionsCompanion data) {
    return ConnectionRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      configJson: data.configJson.present
          ? data.configJson.value
          : this.configJson,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastAuthenticatedAt: data.lastAuthenticatedAt.present
          ? data.lastAuthenticatedAt.value
          : this.lastAuthenticatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConnectionRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('displayName: $displayName, ')
          ..write('configJson: $configJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastAuthenticatedAt: $lastAuthenticatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    displayName,
    configJson,
    createdAt,
    lastAuthenticatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConnectionRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.displayName == this.displayName &&
          other.configJson == this.configJson &&
          other.createdAt == this.createdAt &&
          other.lastAuthenticatedAt == this.lastAuthenticatedAt);
}

class ConnectionsCompanion extends UpdateCompanion<ConnectionRow> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String> displayName;
  final Value<String> configJson;
  final Value<int> createdAt;
  final Value<int?> lastAuthenticatedAt;
  final Value<int> rowid;
  const ConnectionsCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.displayName = const Value.absent(),
    this.configJson = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastAuthenticatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConnectionsCompanion.insert({
    required String id,
    required String kind,
    required String displayName,
    required String configJson,
    required int createdAt,
    this.lastAuthenticatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       displayName = Value(displayName),
       configJson = Value(configJson),
       createdAt = Value(createdAt);
  static Insertable<ConnectionRow> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? displayName,
    Expression<String>? configJson,
    Expression<int>? createdAt,
    Expression<int>? lastAuthenticatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (displayName != null) 'display_name': displayName,
      if (configJson != null) 'config_json': configJson,
      if (createdAt != null) 'created_at': createdAt,
      if (lastAuthenticatedAt != null)
        'last_authenticated_at': lastAuthenticatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConnectionsCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String>? displayName,
    Value<String>? configJson,
    Value<int>? createdAt,
    Value<int?>? lastAuthenticatedAt,
    Value<int>? rowid,
  }) {
    return ConnectionsCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      displayName: displayName ?? this.displayName,
      configJson: configJson ?? this.configJson,
      createdAt: createdAt ?? this.createdAt,
      lastAuthenticatedAt: lastAuthenticatedAt ?? this.lastAuthenticatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (configJson.present) {
      map['config_json'] = Variable<String>(configJson.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (lastAuthenticatedAt.present) {
      map['last_authenticated_at'] = Variable<int>(lastAuthenticatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConnectionsCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('displayName: $displayName, ')
          ..write('configJson: $configJson, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastAuthenticatedAt: $lastAuthenticatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProfilesTable extends Profiles
    with TableInfo<$ProfilesTable, ProfileRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _avatarThumbUrlMeta = const VerificationMeta(
    'avatarThumbUrl',
  );
  @override
  late final GeneratedColumn<String> avatarThumbUrl = GeneratedColumn<String>(
    'avatar_thumb_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _configJsonMeta = const VerificationMeta(
    'configJson',
  );
  @override
  late final GeneratedColumn<String> configJson = GeneratedColumn<String>(
    'config_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _lastUsedAtMeta = const VerificationMeta(
    'lastUsedAt',
  );
  @override
  late final GeneratedColumn<int> lastUsedAt = GeneratedColumn<int>(
    'last_used_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    displayName,
    avatarThumbUrl,
    configJson,
    sortOrder,
    createdAt,
    lastUsedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profiles';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProfileRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('avatar_thumb_url')) {
      context.handle(
        _avatarThumbUrlMeta,
        avatarThumbUrl.isAcceptableOrUnknown(
          data['avatar_thumb_url']!,
          _avatarThumbUrlMeta,
        ),
      );
    }
    if (data.containsKey('config_json')) {
      context.handle(
        _configJsonMeta,
        configJson.isAcceptableOrUnknown(data['config_json']!, _configJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_configJsonMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('last_used_at')) {
      context.handle(
        _lastUsedAtMeta,
        lastUsedAt.isAcceptableOrUnknown(
          data['last_used_at']!,
          _lastUsedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ProfileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProfileRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      avatarThumbUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}avatar_thumb_url'],
      ),
      configJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}config_json'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      lastUsedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_used_at'],
      ),
    );
  }

  @override
  $ProfilesTable createAlias(String alias) {
    return $ProfilesTable(attachedDatabase, alias);
  }
}

class ProfileRow extends DataClass implements Insertable<ProfileRow> {
  /// Stable identifier. For Plex Home profiles: `plex-home-{accountId}-{homeUserUuid}`
  /// (deterministic so re-discovery is idempotent). For locals: `local-{uuid}`.
  final String id;

  /// `'local'` | `'plex_home'`.
  final String kind;
  final String displayName;

  /// Plex Home users have a thumb URL; locals fall back to initials/colour.
  final String? avatarThumbUrl;

  /// Per-kind config:
  /// - `local`: `{ "pinHash": "..." }`
  /// - `plex_home`: `{ "restricted": bool, "admin": bool, "hasPassword": bool, "parentConnectionId": "..." }`
  final String configJson;
  final int sortOrder;
  final int createdAt;
  final int? lastUsedAt;
  const ProfileRow({
    required this.id,
    required this.kind,
    required this.displayName,
    this.avatarThumbUrl,
    required this.configJson,
    required this.sortOrder,
    required this.createdAt,
    this.lastUsedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    map['display_name'] = Variable<String>(displayName);
    if (!nullToAbsent || avatarThumbUrl != null) {
      map['avatar_thumb_url'] = Variable<String>(avatarThumbUrl);
    }
    map['config_json'] = Variable<String>(configJson);
    map['sort_order'] = Variable<int>(sortOrder);
    map['created_at'] = Variable<int>(createdAt);
    if (!nullToAbsent || lastUsedAt != null) {
      map['last_used_at'] = Variable<int>(lastUsedAt);
    }
    return map;
  }

  ProfilesCompanion toCompanion(bool nullToAbsent) {
    return ProfilesCompanion(
      id: Value(id),
      kind: Value(kind),
      displayName: Value(displayName),
      avatarThumbUrl: avatarThumbUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(avatarThumbUrl),
      configJson: Value(configJson),
      sortOrder: Value(sortOrder),
      createdAt: Value(createdAt),
      lastUsedAt: lastUsedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastUsedAt),
    );
  }

  factory ProfileRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProfileRow(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      displayName: serializer.fromJson<String>(json['displayName']),
      avatarThumbUrl: serializer.fromJson<String?>(json['avatarThumbUrl']),
      configJson: serializer.fromJson<String>(json['configJson']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      lastUsedAt: serializer.fromJson<int?>(json['lastUsedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'displayName': serializer.toJson<String>(displayName),
      'avatarThumbUrl': serializer.toJson<String?>(avatarThumbUrl),
      'configJson': serializer.toJson<String>(configJson),
      'sortOrder': serializer.toJson<int>(sortOrder),
      'createdAt': serializer.toJson<int>(createdAt),
      'lastUsedAt': serializer.toJson<int?>(lastUsedAt),
    };
  }

  ProfileRow copyWith({
    String? id,
    String? kind,
    String? displayName,
    Value<String?> avatarThumbUrl = const Value.absent(),
    String? configJson,
    int? sortOrder,
    int? createdAt,
    Value<int?> lastUsedAt = const Value.absent(),
  }) => ProfileRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    displayName: displayName ?? this.displayName,
    avatarThumbUrl: avatarThumbUrl.present
        ? avatarThumbUrl.value
        : this.avatarThumbUrl,
    configJson: configJson ?? this.configJson,
    sortOrder: sortOrder ?? this.sortOrder,
    createdAt: createdAt ?? this.createdAt,
    lastUsedAt: lastUsedAt.present ? lastUsedAt.value : this.lastUsedAt,
  );
  ProfileRow copyWithCompanion(ProfilesCompanion data) {
    return ProfileRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      avatarThumbUrl: data.avatarThumbUrl.present
          ? data.avatarThumbUrl.value
          : this.avatarThumbUrl,
      configJson: data.configJson.present
          ? data.configJson.value
          : this.configJson,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      lastUsedAt: data.lastUsedAt.present
          ? data.lastUsedAt.value
          : this.lastUsedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProfileRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('displayName: $displayName, ')
          ..write('avatarThumbUrl: $avatarThumbUrl, ')
          ..write('configJson: $configJson, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastUsedAt: $lastUsedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    displayName,
    avatarThumbUrl,
    configJson,
    sortOrder,
    createdAt,
    lastUsedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProfileRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.displayName == this.displayName &&
          other.avatarThumbUrl == this.avatarThumbUrl &&
          other.configJson == this.configJson &&
          other.sortOrder == this.sortOrder &&
          other.createdAt == this.createdAt &&
          other.lastUsedAt == this.lastUsedAt);
}

class ProfilesCompanion extends UpdateCompanion<ProfileRow> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String> displayName;
  final Value<String?> avatarThumbUrl;
  final Value<String> configJson;
  final Value<int> sortOrder;
  final Value<int> createdAt;
  final Value<int?> lastUsedAt;
  final Value<int> rowid;
  const ProfilesCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.displayName = const Value.absent(),
    this.avatarThumbUrl = const Value.absent(),
    this.configJson = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.lastUsedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProfilesCompanion.insert({
    required String id,
    required String kind,
    required String displayName,
    this.avatarThumbUrl = const Value.absent(),
    required String configJson,
    this.sortOrder = const Value.absent(),
    required int createdAt,
    this.lastUsedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       displayName = Value(displayName),
       configJson = Value(configJson),
       createdAt = Value(createdAt);
  static Insertable<ProfileRow> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? displayName,
    Expression<String>? avatarThumbUrl,
    Expression<String>? configJson,
    Expression<int>? sortOrder,
    Expression<int>? createdAt,
    Expression<int>? lastUsedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (displayName != null) 'display_name': displayName,
      if (avatarThumbUrl != null) 'avatar_thumb_url': avatarThumbUrl,
      if (configJson != null) 'config_json': configJson,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (createdAt != null) 'created_at': createdAt,
      if (lastUsedAt != null) 'last_used_at': lastUsedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProfilesCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String>? displayName,
    Value<String?>? avatarThumbUrl,
    Value<String>? configJson,
    Value<int>? sortOrder,
    Value<int>? createdAt,
    Value<int?>? lastUsedAt,
    Value<int>? rowid,
  }) {
    return ProfilesCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      displayName: displayName ?? this.displayName,
      avatarThumbUrl: avatarThumbUrl ?? this.avatarThumbUrl,
      configJson: configJson ?? this.configJson,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt ?? this.createdAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (avatarThumbUrl.present) {
      map['avatar_thumb_url'] = Variable<String>(avatarThumbUrl.value);
    }
    if (configJson.present) {
      map['config_json'] = Variable<String>(configJson.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (lastUsedAt.present) {
      map['last_used_at'] = Variable<int>(lastUsedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfilesCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('displayName: $displayName, ')
          ..write('avatarThumbUrl: $avatarThumbUrl, ')
          ..write('configJson: $configJson, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('createdAt: $createdAt, ')
          ..write('lastUsedAt: $lastUsedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $ProfileConnectionsTable extends ProfileConnections
    with TableInfo<$ProfileConnectionsTable, ProfileConnectionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ProfileConnectionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _connectionIdMeta = const VerificationMeta(
    'connectionId',
  );
  @override
  late final GeneratedColumn<String> connectionId = GeneratedColumn<String>(
    'connection_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES connections (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _userTokenMeta = const VerificationMeta(
    'userToken',
  );
  @override
  late final GeneratedColumn<String> userToken = GeneratedColumn<String>(
    'user_token',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _userIdentifierMeta = const VerificationMeta(
    'userIdentifier',
  );
  @override
  late final GeneratedColumn<String> userIdentifier = GeneratedColumn<String>(
    'user_identifier',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _isDefaultMeta = const VerificationMeta(
    'isDefault',
  );
  @override
  late final GeneratedColumn<bool> isDefault = GeneratedColumn<bool>(
    'is_default',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("is_default" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _tokenAcquiredAtMeta = const VerificationMeta(
    'tokenAcquiredAt',
  );
  @override
  late final GeneratedColumn<int> tokenAcquiredAt = GeneratedColumn<int>(
    'token_acquired_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastUsedAtMeta = const VerificationMeta(
    'lastUsedAt',
  );
  @override
  late final GeneratedColumn<int> lastUsedAt = GeneratedColumn<int>(
    'last_used_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    connectionId,
    userToken,
    userIdentifier,
    isDefault,
    tokenAcquiredAt,
    lastUsedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'profile_connections';
  @override
  VerificationContext validateIntegrity(
    Insertable<ProfileConnectionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('connection_id')) {
      context.handle(
        _connectionIdMeta,
        connectionId.isAcceptableOrUnknown(
          data['connection_id']!,
          _connectionIdMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_connectionIdMeta);
    }
    if (data.containsKey('user_token')) {
      context.handle(
        _userTokenMeta,
        userToken.isAcceptableOrUnknown(data['user_token']!, _userTokenMeta),
      );
    }
    if (data.containsKey('user_identifier')) {
      context.handle(
        _userIdentifierMeta,
        userIdentifier.isAcceptableOrUnknown(
          data['user_identifier']!,
          _userIdentifierMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_userIdentifierMeta);
    }
    if (data.containsKey('is_default')) {
      context.handle(
        _isDefaultMeta,
        isDefault.isAcceptableOrUnknown(data['is_default']!, _isDefaultMeta),
      );
    }
    if (data.containsKey('token_acquired_at')) {
      context.handle(
        _tokenAcquiredAtMeta,
        tokenAcquiredAt.isAcceptableOrUnknown(
          data['token_acquired_at']!,
          _tokenAcquiredAtMeta,
        ),
      );
    }
    if (data.containsKey('last_used_at')) {
      context.handle(
        _lastUsedAtMeta,
        lastUsedAt.isAcceptableOrUnknown(
          data['last_used_at']!,
          _lastUsedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId, connectionId};
  @override
  ProfileConnectionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ProfileConnectionRow(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      connectionId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}connection_id'],
      )!,
      userToken: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_token'],
      )!,
      userIdentifier: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_identifier'],
      )!,
      isDefault: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}is_default'],
      )!,
      tokenAcquiredAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}token_acquired_at'],
      ),
      lastUsedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_used_at'],
      ),
    );
  }

  @override
  $ProfileConnectionsTable createAlias(String alias) {
    return $ProfileConnectionsTable(attachedDatabase, alias);
  }
}

class ProfileConnectionRow extends DataClass
    implements Insertable<ProfileConnectionRow> {
  final String profileId;
  final String connectionId;
  final String userToken;
  final String userIdentifier;
  final bool isDefault;
  final int? tokenAcquiredAt;
  final int? lastUsedAt;
  const ProfileConnectionRow({
    required this.profileId,
    required this.connectionId,
    required this.userToken,
    required this.userIdentifier,
    required this.isDefault,
    this.tokenAcquiredAt,
    this.lastUsedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['connection_id'] = Variable<String>(connectionId);
    map['user_token'] = Variable<String>(userToken);
    map['user_identifier'] = Variable<String>(userIdentifier);
    map['is_default'] = Variable<bool>(isDefault);
    if (!nullToAbsent || tokenAcquiredAt != null) {
      map['token_acquired_at'] = Variable<int>(tokenAcquiredAt);
    }
    if (!nullToAbsent || lastUsedAt != null) {
      map['last_used_at'] = Variable<int>(lastUsedAt);
    }
    return map;
  }

  ProfileConnectionsCompanion toCompanion(bool nullToAbsent) {
    return ProfileConnectionsCompanion(
      profileId: Value(profileId),
      connectionId: Value(connectionId),
      userToken: Value(userToken),
      userIdentifier: Value(userIdentifier),
      isDefault: Value(isDefault),
      tokenAcquiredAt: tokenAcquiredAt == null && nullToAbsent
          ? const Value.absent()
          : Value(tokenAcquiredAt),
      lastUsedAt: lastUsedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastUsedAt),
    );
  }

  factory ProfileConnectionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ProfileConnectionRow(
      profileId: serializer.fromJson<String>(json['profileId']),
      connectionId: serializer.fromJson<String>(json['connectionId']),
      userToken: serializer.fromJson<String>(json['userToken']),
      userIdentifier: serializer.fromJson<String>(json['userIdentifier']),
      isDefault: serializer.fromJson<bool>(json['isDefault']),
      tokenAcquiredAt: serializer.fromJson<int?>(json['tokenAcquiredAt']),
      lastUsedAt: serializer.fromJson<int?>(json['lastUsedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'connectionId': serializer.toJson<String>(connectionId),
      'userToken': serializer.toJson<String>(userToken),
      'userIdentifier': serializer.toJson<String>(userIdentifier),
      'isDefault': serializer.toJson<bool>(isDefault),
      'tokenAcquiredAt': serializer.toJson<int?>(tokenAcquiredAt),
      'lastUsedAt': serializer.toJson<int?>(lastUsedAt),
    };
  }

  ProfileConnectionRow copyWith({
    String? profileId,
    String? connectionId,
    String? userToken,
    String? userIdentifier,
    bool? isDefault,
    Value<int?> tokenAcquiredAt = const Value.absent(),
    Value<int?> lastUsedAt = const Value.absent(),
  }) => ProfileConnectionRow(
    profileId: profileId ?? this.profileId,
    connectionId: connectionId ?? this.connectionId,
    userToken: userToken ?? this.userToken,
    userIdentifier: userIdentifier ?? this.userIdentifier,
    isDefault: isDefault ?? this.isDefault,
    tokenAcquiredAt: tokenAcquiredAt.present
        ? tokenAcquiredAt.value
        : this.tokenAcquiredAt,
    lastUsedAt: lastUsedAt.present ? lastUsedAt.value : this.lastUsedAt,
  );
  ProfileConnectionRow copyWithCompanion(ProfileConnectionsCompanion data) {
    return ProfileConnectionRow(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      connectionId: data.connectionId.present
          ? data.connectionId.value
          : this.connectionId,
      userToken: data.userToken.present ? data.userToken.value : this.userToken,
      userIdentifier: data.userIdentifier.present
          ? data.userIdentifier.value
          : this.userIdentifier,
      isDefault: data.isDefault.present ? data.isDefault.value : this.isDefault,
      tokenAcquiredAt: data.tokenAcquiredAt.present
          ? data.tokenAcquiredAt.value
          : this.tokenAcquiredAt,
      lastUsedAt: data.lastUsedAt.present
          ? data.lastUsedAt.value
          : this.lastUsedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ProfileConnectionRow(')
          ..write('profileId: $profileId, ')
          ..write('connectionId: $connectionId, ')
          ..write('userToken: $userToken, ')
          ..write('userIdentifier: $userIdentifier, ')
          ..write('isDefault: $isDefault, ')
          ..write('tokenAcquiredAt: $tokenAcquiredAt, ')
          ..write('lastUsedAt: $lastUsedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    profileId,
    connectionId,
    userToken,
    userIdentifier,
    isDefault,
    tokenAcquiredAt,
    lastUsedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ProfileConnectionRow &&
          other.profileId == this.profileId &&
          other.connectionId == this.connectionId &&
          other.userToken == this.userToken &&
          other.userIdentifier == this.userIdentifier &&
          other.isDefault == this.isDefault &&
          other.tokenAcquiredAt == this.tokenAcquiredAt &&
          other.lastUsedAt == this.lastUsedAt);
}

class ProfileConnectionsCompanion
    extends UpdateCompanion<ProfileConnectionRow> {
  final Value<String> profileId;
  final Value<String> connectionId;
  final Value<String> userToken;
  final Value<String> userIdentifier;
  final Value<bool> isDefault;
  final Value<int?> tokenAcquiredAt;
  final Value<int?> lastUsedAt;
  final Value<int> rowid;
  const ProfileConnectionsCompanion({
    this.profileId = const Value.absent(),
    this.connectionId = const Value.absent(),
    this.userToken = const Value.absent(),
    this.userIdentifier = const Value.absent(),
    this.isDefault = const Value.absent(),
    this.tokenAcquiredAt = const Value.absent(),
    this.lastUsedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ProfileConnectionsCompanion.insert({
    required String profileId,
    required String connectionId,
    this.userToken = const Value.absent(),
    required String userIdentifier,
    this.isDefault = const Value.absent(),
    this.tokenAcquiredAt = const Value.absent(),
    this.lastUsedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       connectionId = Value(connectionId),
       userIdentifier = Value(userIdentifier);
  static Insertable<ProfileConnectionRow> custom({
    Expression<String>? profileId,
    Expression<String>? connectionId,
    Expression<String>? userToken,
    Expression<String>? userIdentifier,
    Expression<bool>? isDefault,
    Expression<int>? tokenAcquiredAt,
    Expression<int>? lastUsedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (connectionId != null) 'connection_id': connectionId,
      if (userToken != null) 'user_token': userToken,
      if (userIdentifier != null) 'user_identifier': userIdentifier,
      if (isDefault != null) 'is_default': isDefault,
      if (tokenAcquiredAt != null) 'token_acquired_at': tokenAcquiredAt,
      if (lastUsedAt != null) 'last_used_at': lastUsedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ProfileConnectionsCompanion copyWith({
    Value<String>? profileId,
    Value<String>? connectionId,
    Value<String>? userToken,
    Value<String>? userIdentifier,
    Value<bool>? isDefault,
    Value<int?>? tokenAcquiredAt,
    Value<int?>? lastUsedAt,
    Value<int>? rowid,
  }) {
    return ProfileConnectionsCompanion(
      profileId: profileId ?? this.profileId,
      connectionId: connectionId ?? this.connectionId,
      userToken: userToken ?? this.userToken,
      userIdentifier: userIdentifier ?? this.userIdentifier,
      isDefault: isDefault ?? this.isDefault,
      tokenAcquiredAt: tokenAcquiredAt ?? this.tokenAcquiredAt,
      lastUsedAt: lastUsedAt ?? this.lastUsedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (connectionId.present) {
      map['connection_id'] = Variable<String>(connectionId.value);
    }
    if (userToken.present) {
      map['user_token'] = Variable<String>(userToken.value);
    }
    if (userIdentifier.present) {
      map['user_identifier'] = Variable<String>(userIdentifier.value);
    }
    if (isDefault.present) {
      map['is_default'] = Variable<bool>(isDefault.value);
    }
    if (tokenAcquiredAt.present) {
      map['token_acquired_at'] = Variable<int>(tokenAcquiredAt.value);
    }
    if (lastUsedAt.present) {
      map['last_used_at'] = Variable<int>(lastUsedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ProfileConnectionsCompanion(')
          ..write('profileId: $profileId, ')
          ..write('connectionId: $connectionId, ')
          ..write('userToken: $userToken, ')
          ..write('userIdentifier: $userIdentifier, ')
          ..write('isDefault: $isDefault, ')
          ..write('tokenAcquiredAt: $tokenAcquiredAt, ')
          ..write('lastUsedAt: $lastUsedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MusicSessionsTable extends MusicSessions
    with TableInfo<$MusicSessionsTable, MusicSessionRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MusicSessionsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _profileIdMeta = const VerificationMeta(
    'profileId',
  );
  @override
  late final GeneratedColumn<String> profileId = GeneratedColumn<String>(
    'profile_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _queueJsonMeta = const VerificationMeta(
    'queueJson',
  );
  @override
  late final GeneratedColumn<String> queueJson = GeneratedColumn<String>(
    'queue_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _orderJsonMeta = const VerificationMeta(
    'orderJson',
  );
  @override
  late final GeneratedColumn<String> orderJson = GeneratedColumn<String>(
    'order_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _cursorMeta = const VerificationMeta('cursor');
  @override
  late final GeneratedColumn<int> cursor = GeneratedColumn<int>(
    'cursor',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _shuffledMeta = const VerificationMeta(
    'shuffled',
  );
  @override
  late final GeneratedColumn<bool> shuffled = GeneratedColumn<bool>(
    'shuffled',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("shuffled" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _repeatModeMeta = const VerificationMeta(
    'repeatMode',
  );
  @override
  late final GeneratedColumn<String> repeatMode = GeneratedColumn<String>(
    'repeat_mode',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('off'),
  );
  static const VerificationMeta _contextTitleMeta = const VerificationMeta(
    'contextTitle',
  );
  @override
  late final GeneratedColumn<String> contextTitle = GeneratedColumn<String>(
    'context_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contextKindMeta = const VerificationMeta(
    'contextKind',
  );
  @override
  late final GeneratedColumn<String> contextKind = GeneratedColumn<String>(
    'context_kind',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _positionMsMeta = const VerificationMeta(
    'positionMs',
  );
  @override
  late final GeneratedColumn<int> positionMs = GeneratedColumn<int>(
    'position_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    profileId,
    queueJson,
    orderJson,
    cursor,
    shuffled,
    repeatMode,
    contextTitle,
    contextKind,
    positionMs,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'music_sessions';
  @override
  VerificationContext validateIntegrity(
    Insertable<MusicSessionRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('profile_id')) {
      context.handle(
        _profileIdMeta,
        profileId.isAcceptableOrUnknown(data['profile_id']!, _profileIdMeta),
      );
    } else if (isInserting) {
      context.missing(_profileIdMeta);
    }
    if (data.containsKey('queue_json')) {
      context.handle(
        _queueJsonMeta,
        queueJson.isAcceptableOrUnknown(data['queue_json']!, _queueJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_queueJsonMeta);
    }
    if (data.containsKey('order_json')) {
      context.handle(
        _orderJsonMeta,
        orderJson.isAcceptableOrUnknown(data['order_json']!, _orderJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_orderJsonMeta);
    }
    if (data.containsKey('cursor')) {
      context.handle(
        _cursorMeta,
        cursor.isAcceptableOrUnknown(data['cursor']!, _cursorMeta),
      );
    } else if (isInserting) {
      context.missing(_cursorMeta);
    }
    if (data.containsKey('shuffled')) {
      context.handle(
        _shuffledMeta,
        shuffled.isAcceptableOrUnknown(data['shuffled']!, _shuffledMeta),
      );
    }
    if (data.containsKey('repeat_mode')) {
      context.handle(
        _repeatModeMeta,
        repeatMode.isAcceptableOrUnknown(data['repeat_mode']!, _repeatModeMeta),
      );
    }
    if (data.containsKey('context_title')) {
      context.handle(
        _contextTitleMeta,
        contextTitle.isAcceptableOrUnknown(
          data['context_title']!,
          _contextTitleMeta,
        ),
      );
    }
    if (data.containsKey('context_kind')) {
      context.handle(
        _contextKindMeta,
        contextKind.isAcceptableOrUnknown(
          data['context_kind']!,
          _contextKindMeta,
        ),
      );
    }
    if (data.containsKey('position_ms')) {
      context.handle(
        _positionMsMeta,
        positionMs.isAcceptableOrUnknown(data['position_ms']!, _positionMsMeta),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {profileId};
  @override
  MusicSessionRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MusicSessionRow(
      profileId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}profile_id'],
      )!,
      queueJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}queue_json'],
      )!,
      orderJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}order_json'],
      )!,
      cursor: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}cursor'],
      )!,
      shuffled: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}shuffled'],
      )!,
      repeatMode: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}repeat_mode'],
      )!,
      contextTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}context_title'],
      ),
      contextKind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}context_kind'],
      ),
      positionMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position_ms'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $MusicSessionsTable createAlias(String alias) {
    return $MusicSessionsTable(attachedDatabase, alias);
  }
}

class MusicSessionRow extends DataClass implements Insertable<MusicSessionRow> {
  /// Active Plezy profile that owns this session snapshot.
  final String profileId;

  /// Canonical queue tracks (insertion order) as a JSON array of MediaItem
  /// JSON — self-contained so restore never depends on volatile cache rows.
  final String queueJson;

  /// Playback-order permutation into [queueJson] as a JSON int array
  /// (identity while unshuffled).
  final String orderJson;

  /// Position of the current track within the playback order.
  final int cursor;
  final bool shuffled;

  /// Stable repeat-mode id ('off' | 'all' | 'one') — not the enum `.name`.
  final String repeatMode;

  /// Play-context provenance ("Playing from …"); kind is a stable id.
  final String? contextTitle;
  final String? contextKind;

  /// Playhead within the current track in milliseconds.
  final int positionMs;

  /// Timestamp of the last write (milliseconds since epoch).
  final int updatedAt;
  const MusicSessionRow({
    required this.profileId,
    required this.queueJson,
    required this.orderJson,
    required this.cursor,
    required this.shuffled,
    required this.repeatMode,
    this.contextTitle,
    this.contextKind,
    required this.positionMs,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['profile_id'] = Variable<String>(profileId);
    map['queue_json'] = Variable<String>(queueJson);
    map['order_json'] = Variable<String>(orderJson);
    map['cursor'] = Variable<int>(cursor);
    map['shuffled'] = Variable<bool>(shuffled);
    map['repeat_mode'] = Variable<String>(repeatMode);
    if (!nullToAbsent || contextTitle != null) {
      map['context_title'] = Variable<String>(contextTitle);
    }
    if (!nullToAbsent || contextKind != null) {
      map['context_kind'] = Variable<String>(contextKind);
    }
    map['position_ms'] = Variable<int>(positionMs);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  MusicSessionsCompanion toCompanion(bool nullToAbsent) {
    return MusicSessionsCompanion(
      profileId: Value(profileId),
      queueJson: Value(queueJson),
      orderJson: Value(orderJson),
      cursor: Value(cursor),
      shuffled: Value(shuffled),
      repeatMode: Value(repeatMode),
      contextTitle: contextTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(contextTitle),
      contextKind: contextKind == null && nullToAbsent
          ? const Value.absent()
          : Value(contextKind),
      positionMs: Value(positionMs),
      updatedAt: Value(updatedAt),
    );
  }

  factory MusicSessionRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MusicSessionRow(
      profileId: serializer.fromJson<String>(json['profileId']),
      queueJson: serializer.fromJson<String>(json['queueJson']),
      orderJson: serializer.fromJson<String>(json['orderJson']),
      cursor: serializer.fromJson<int>(json['cursor']),
      shuffled: serializer.fromJson<bool>(json['shuffled']),
      repeatMode: serializer.fromJson<String>(json['repeatMode']),
      contextTitle: serializer.fromJson<String?>(json['contextTitle']),
      contextKind: serializer.fromJson<String?>(json['contextKind']),
      positionMs: serializer.fromJson<int>(json['positionMs']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'profileId': serializer.toJson<String>(profileId),
      'queueJson': serializer.toJson<String>(queueJson),
      'orderJson': serializer.toJson<String>(orderJson),
      'cursor': serializer.toJson<int>(cursor),
      'shuffled': serializer.toJson<bool>(shuffled),
      'repeatMode': serializer.toJson<String>(repeatMode),
      'contextTitle': serializer.toJson<String?>(contextTitle),
      'contextKind': serializer.toJson<String?>(contextKind),
      'positionMs': serializer.toJson<int>(positionMs),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  MusicSessionRow copyWith({
    String? profileId,
    String? queueJson,
    String? orderJson,
    int? cursor,
    bool? shuffled,
    String? repeatMode,
    Value<String?> contextTitle = const Value.absent(),
    Value<String?> contextKind = const Value.absent(),
    int? positionMs,
    int? updatedAt,
  }) => MusicSessionRow(
    profileId: profileId ?? this.profileId,
    queueJson: queueJson ?? this.queueJson,
    orderJson: orderJson ?? this.orderJson,
    cursor: cursor ?? this.cursor,
    shuffled: shuffled ?? this.shuffled,
    repeatMode: repeatMode ?? this.repeatMode,
    contextTitle: contextTitle.present ? contextTitle.value : this.contextTitle,
    contextKind: contextKind.present ? contextKind.value : this.contextKind,
    positionMs: positionMs ?? this.positionMs,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  MusicSessionRow copyWithCompanion(MusicSessionsCompanion data) {
    return MusicSessionRow(
      profileId: data.profileId.present ? data.profileId.value : this.profileId,
      queueJson: data.queueJson.present ? data.queueJson.value : this.queueJson,
      orderJson: data.orderJson.present ? data.orderJson.value : this.orderJson,
      cursor: data.cursor.present ? data.cursor.value : this.cursor,
      shuffled: data.shuffled.present ? data.shuffled.value : this.shuffled,
      repeatMode: data.repeatMode.present
          ? data.repeatMode.value
          : this.repeatMode,
      contextTitle: data.contextTitle.present
          ? data.contextTitle.value
          : this.contextTitle,
      contextKind: data.contextKind.present
          ? data.contextKind.value
          : this.contextKind,
      positionMs: data.positionMs.present
          ? data.positionMs.value
          : this.positionMs,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MusicSessionRow(')
          ..write('profileId: $profileId, ')
          ..write('queueJson: $queueJson, ')
          ..write('orderJson: $orderJson, ')
          ..write('cursor: $cursor, ')
          ..write('shuffled: $shuffled, ')
          ..write('repeatMode: $repeatMode, ')
          ..write('contextTitle: $contextTitle, ')
          ..write('contextKind: $contextKind, ')
          ..write('positionMs: $positionMs, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    profileId,
    queueJson,
    orderJson,
    cursor,
    shuffled,
    repeatMode,
    contextTitle,
    contextKind,
    positionMs,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MusicSessionRow &&
          other.profileId == this.profileId &&
          other.queueJson == this.queueJson &&
          other.orderJson == this.orderJson &&
          other.cursor == this.cursor &&
          other.shuffled == this.shuffled &&
          other.repeatMode == this.repeatMode &&
          other.contextTitle == this.contextTitle &&
          other.contextKind == this.contextKind &&
          other.positionMs == this.positionMs &&
          other.updatedAt == this.updatedAt);
}

class MusicSessionsCompanion extends UpdateCompanion<MusicSessionRow> {
  final Value<String> profileId;
  final Value<String> queueJson;
  final Value<String> orderJson;
  final Value<int> cursor;
  final Value<bool> shuffled;
  final Value<String> repeatMode;
  final Value<String?> contextTitle;
  final Value<String?> contextKind;
  final Value<int> positionMs;
  final Value<int> updatedAt;
  final Value<int> rowid;
  const MusicSessionsCompanion({
    this.profileId = const Value.absent(),
    this.queueJson = const Value.absent(),
    this.orderJson = const Value.absent(),
    this.cursor = const Value.absent(),
    this.shuffled = const Value.absent(),
    this.repeatMode = const Value.absent(),
    this.contextTitle = const Value.absent(),
    this.contextKind = const Value.absent(),
    this.positionMs = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MusicSessionsCompanion.insert({
    required String profileId,
    required String queueJson,
    required String orderJson,
    required int cursor,
    this.shuffled = const Value.absent(),
    this.repeatMode = const Value.absent(),
    this.contextTitle = const Value.absent(),
    this.contextKind = const Value.absent(),
    this.positionMs = const Value.absent(),
    required int updatedAt,
    this.rowid = const Value.absent(),
  }) : profileId = Value(profileId),
       queueJson = Value(queueJson),
       orderJson = Value(orderJson),
       cursor = Value(cursor),
       updatedAt = Value(updatedAt);
  static Insertable<MusicSessionRow> custom({
    Expression<String>? profileId,
    Expression<String>? queueJson,
    Expression<String>? orderJson,
    Expression<int>? cursor,
    Expression<bool>? shuffled,
    Expression<String>? repeatMode,
    Expression<String>? contextTitle,
    Expression<String>? contextKind,
    Expression<int>? positionMs,
    Expression<int>? updatedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (profileId != null) 'profile_id': profileId,
      if (queueJson != null) 'queue_json': queueJson,
      if (orderJson != null) 'order_json': orderJson,
      if (cursor != null) 'cursor': cursor,
      if (shuffled != null) 'shuffled': shuffled,
      if (repeatMode != null) 'repeat_mode': repeatMode,
      if (contextTitle != null) 'context_title': contextTitle,
      if (contextKind != null) 'context_kind': contextKind,
      if (positionMs != null) 'position_ms': positionMs,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MusicSessionsCompanion copyWith({
    Value<String>? profileId,
    Value<String>? queueJson,
    Value<String>? orderJson,
    Value<int>? cursor,
    Value<bool>? shuffled,
    Value<String>? repeatMode,
    Value<String?>? contextTitle,
    Value<String?>? contextKind,
    Value<int>? positionMs,
    Value<int>? updatedAt,
    Value<int>? rowid,
  }) {
    return MusicSessionsCompanion(
      profileId: profileId ?? this.profileId,
      queueJson: queueJson ?? this.queueJson,
      orderJson: orderJson ?? this.orderJson,
      cursor: cursor ?? this.cursor,
      shuffled: shuffled ?? this.shuffled,
      repeatMode: repeatMode ?? this.repeatMode,
      contextTitle: contextTitle ?? this.contextTitle,
      contextKind: contextKind ?? this.contextKind,
      positionMs: positionMs ?? this.positionMs,
      updatedAt: updatedAt ?? this.updatedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (profileId.present) {
      map['profile_id'] = Variable<String>(profileId.value);
    }
    if (queueJson.present) {
      map['queue_json'] = Variable<String>(queueJson.value);
    }
    if (orderJson.present) {
      map['order_json'] = Variable<String>(orderJson.value);
    }
    if (cursor.present) {
      map['cursor'] = Variable<int>(cursor.value);
    }
    if (shuffled.present) {
      map['shuffled'] = Variable<bool>(shuffled.value);
    }
    if (repeatMode.present) {
      map['repeat_mode'] = Variable<String>(repeatMode.value);
    }
    if (contextTitle.present) {
      map['context_title'] = Variable<String>(contextTitle.value);
    }
    if (contextKind.present) {
      map['context_kind'] = Variable<String>(contextKind.value);
    }
    if (positionMs.present) {
      map['position_ms'] = Variable<int>(positionMs.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MusicSessionsCompanion(')
          ..write('profileId: $profileId, ')
          ..write('queueJson: $queueJson, ')
          ..write('orderJson: $orderJson, ')
          ..write('cursor: $cursor, ')
          ..write('shuffled: $shuffled, ')
          ..write('repeatMode: $repeatMode, ')
          ..write('contextTitle: $contextTitle, ')
          ..write('contextKind: $contextKind, ')
          ..write('positionMs: $positionMs, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MountsTable extends Mounts with TableInfo<$MountsTable, MountRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MountsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _displayNameMeta = const VerificationMeta(
    'displayName',
  );
  @override
  late final GeneratedColumn<String> displayName = GeneratedColumn<String>(
    'display_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _libraryTypeMeta = const VerificationMeta(
    'libraryType',
  );
  @override
  late final GeneratedColumn<String> libraryType = GeneratedColumn<String>(
    'library_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('auto'),
  );
  static const VerificationMeta _configJsonMeta = const VerificationMeta(
    'configJson',
  );
  @override
  late final GeneratedColumn<String> configJson = GeneratedColumn<String>(
    'config_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _secretsMeta = const VerificationMeta(
    'secrets',
  );
  @override
  late final GeneratedColumn<String> secrets = GeneratedColumn<String>(
    'secrets',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    displayName,
    libraryType,
    configJson,
    secrets,
    createdAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'mounts';
  @override
  VerificationContext validateIntegrity(
    Insertable<MountRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('display_name')) {
      context.handle(
        _displayNameMeta,
        displayName.isAcceptableOrUnknown(
          data['display_name']!,
          _displayNameMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_displayNameMeta);
    }
    if (data.containsKey('library_type')) {
      context.handle(
        _libraryTypeMeta,
        libraryType.isAcceptableOrUnknown(
          data['library_type']!,
          _libraryTypeMeta,
        ),
      );
    }
    if (data.containsKey('config_json')) {
      context.handle(
        _configJsonMeta,
        configJson.isAcceptableOrUnknown(data['config_json']!, _configJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_configJsonMeta);
    }
    if (data.containsKey('secrets')) {
      context.handle(
        _secretsMeta,
        secrets.isAcceptableOrUnknown(data['secrets']!, _secretsMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MountRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MountRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      displayName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}display_name'],
      )!,
      libraryType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}library_type'],
      )!,
      configJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}config_json'],
      )!,
      secrets: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}secrets'],
      )!,
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
    );
  }

  @override
  $MountsTable createAlias(String alias) {
    return $MountsTable(attachedDatabase, alias);
  }
}

class MountRow extends DataClass implements Insertable<MountRow> {
  /// Generated UUID.
  final String id;

  /// Driver kind: `'local'`, `'webdav'`, `'quark'` or `'smb'`.
  final String kind;

  /// User-visible label.
  final String displayName;

  /// How the scanner classifies content: `'auto'`, `'movie'`, `'show'` or `'anime'`.
  /// Unused: mounts no longer carry a type, the scraper picks each title's
  /// shelf. Kept so the table needs no rebuild.
  final String libraryType;

  /// Driver-specific, non-sensitive settings as a JSON object.
  final String configJson;

  /// Credentials as a JSON object, encrypted by `CredentialVault`. Empty when
  /// the mount has none.
  final String secrets;

  /// Timestamp this mount was added (milliseconds since epoch).
  final int createdAt;
  const MountRow({
    required this.id,
    required this.kind,
    required this.displayName,
    required this.libraryType,
    required this.configJson,
    required this.secrets,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['kind'] = Variable<String>(kind);
    map['display_name'] = Variable<String>(displayName);
    map['library_type'] = Variable<String>(libraryType);
    map['config_json'] = Variable<String>(configJson);
    map['secrets'] = Variable<String>(secrets);
    map['created_at'] = Variable<int>(createdAt);
    return map;
  }

  MountsCompanion toCompanion(bool nullToAbsent) {
    return MountsCompanion(
      id: Value(id),
      kind: Value(kind),
      displayName: Value(displayName),
      libraryType: Value(libraryType),
      configJson: Value(configJson),
      secrets: Value(secrets),
      createdAt: Value(createdAt),
    );
  }

  factory MountRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MountRow(
      id: serializer.fromJson<String>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      displayName: serializer.fromJson<String>(json['displayName']),
      libraryType: serializer.fromJson<String>(json['libraryType']),
      configJson: serializer.fromJson<String>(json['configJson']),
      secrets: serializer.fromJson<String>(json['secrets']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'kind': serializer.toJson<String>(kind),
      'displayName': serializer.toJson<String>(displayName),
      'libraryType': serializer.toJson<String>(libraryType),
      'configJson': serializer.toJson<String>(configJson),
      'secrets': serializer.toJson<String>(secrets),
      'createdAt': serializer.toJson<int>(createdAt),
    };
  }

  MountRow copyWith({
    String? id,
    String? kind,
    String? displayName,
    String? libraryType,
    String? configJson,
    String? secrets,
    int? createdAt,
  }) => MountRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    displayName: displayName ?? this.displayName,
    libraryType: libraryType ?? this.libraryType,
    configJson: configJson ?? this.configJson,
    secrets: secrets ?? this.secrets,
    createdAt: createdAt ?? this.createdAt,
  );
  MountRow copyWithCompanion(MountsCompanion data) {
    return MountRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      displayName: data.displayName.present
          ? data.displayName.value
          : this.displayName,
      libraryType: data.libraryType.present
          ? data.libraryType.value
          : this.libraryType,
      configJson: data.configJson.present
          ? data.configJson.value
          : this.configJson,
      secrets: data.secrets.present ? data.secrets.value : this.secrets,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MountRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('displayName: $displayName, ')
          ..write('libraryType: $libraryType, ')
          ..write('configJson: $configJson, ')
          ..write('secrets: $secrets, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    displayName,
    libraryType,
    configJson,
    secrets,
    createdAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MountRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.displayName == this.displayName &&
          other.libraryType == this.libraryType &&
          other.configJson == this.configJson &&
          other.secrets == this.secrets &&
          other.createdAt == this.createdAt);
}

class MountsCompanion extends UpdateCompanion<MountRow> {
  final Value<String> id;
  final Value<String> kind;
  final Value<String> displayName;
  final Value<String> libraryType;
  final Value<String> configJson;
  final Value<String> secrets;
  final Value<int> createdAt;
  final Value<int> rowid;
  const MountsCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.displayName = const Value.absent(),
    this.libraryType = const Value.absent(),
    this.configJson = const Value.absent(),
    this.secrets = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MountsCompanion.insert({
    required String id,
    required String kind,
    required String displayName,
    this.libraryType = const Value.absent(),
    required String configJson,
    this.secrets = const Value.absent(),
    required int createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       kind = Value(kind),
       displayName = Value(displayName),
       configJson = Value(configJson),
       createdAt = Value(createdAt);
  static Insertable<MountRow> custom({
    Expression<String>? id,
    Expression<String>? kind,
    Expression<String>? displayName,
    Expression<String>? libraryType,
    Expression<String>? configJson,
    Expression<String>? secrets,
    Expression<int>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (displayName != null) 'display_name': displayName,
      if (libraryType != null) 'library_type': libraryType,
      if (configJson != null) 'config_json': configJson,
      if (secrets != null) 'secrets': secrets,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MountsCompanion copyWith({
    Value<String>? id,
    Value<String>? kind,
    Value<String>? displayName,
    Value<String>? libraryType,
    Value<String>? configJson,
    Value<String>? secrets,
    Value<int>? createdAt,
    Value<int>? rowid,
  }) {
    return MountsCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      displayName: displayName ?? this.displayName,
      libraryType: libraryType ?? this.libraryType,
      configJson: configJson ?? this.configJson,
      secrets: secrets ?? this.secrets,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (displayName.present) {
      map['display_name'] = Variable<String>(displayName.value);
    }
    if (libraryType.present) {
      map['library_type'] = Variable<String>(libraryType.value);
    }
    if (configJson.present) {
      map['config_json'] = Variable<String>(configJson.value);
    }
    if (secrets.present) {
      map['secrets'] = Variable<String>(secrets.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MountsCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('displayName: $displayName, ')
          ..write('libraryType: $libraryType, ')
          ..write('configJson: $configJson, ')
          ..write('secrets: $secrets, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LibraryItemsTable extends LibraryItems
    with TableInfo<$LibraryItemsTable, LibraryItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _libraryTypeMeta = const VerificationMeta(
    'libraryType',
  );
  @override
  late final GeneratedColumn<String> libraryType = GeneratedColumn<String>(
    'library_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _parentIdMeta = const VerificationMeta(
    'parentId',
  );
  @override
  late final GeneratedColumn<int> parentId = GeneratedColumn<int>(
    'parent_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_items (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _showIdMeta = const VerificationMeta('showId');
  @override
  late final GeneratedColumn<int> showId = GeneratedColumn<int>(
    'show_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_items (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _sortTitleMeta = const VerificationMeta(
    'sortTitle',
  );
  @override
  late final GeneratedColumn<String> sortTitle = GeneratedColumn<String>(
    'sort_title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _originalTitleMeta = const VerificationMeta(
    'originalTitle',
  );
  @override
  late final GeneratedColumn<String> originalTitle = GeneratedColumn<String>(
    'original_title',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _aliasesMeta = const VerificationMeta(
    'aliases',
  );
  @override
  late final GeneratedColumn<String> aliases = GeneratedColumn<String>(
    'aliases',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _yearMeta = const VerificationMeta('year');
  @override
  late final GeneratedColumn<int> year = GeneratedColumn<int>(
    'year',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _releaseDateMeta = const VerificationMeta(
    'releaseDate',
  );
  @override
  late final GeneratedColumn<String> releaseDate = GeneratedColumn<String>(
    'release_date',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _taglineMeta = const VerificationMeta(
    'tagline',
  );
  @override
  late final GeneratedColumn<String> tagline = GeneratedColumn<String>(
    'tagline',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _contentRatingMeta = const VerificationMeta(
    'contentRating',
  );
  @override
  late final GeneratedColumn<String> contentRating = GeneratedColumn<String>(
    'content_rating',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _studioMeta = const VerificationMeta('studio');
  @override
  late final GeneratedColumn<String> studio = GeneratedColumn<String>(
    'studio',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ratingMeta = const VerificationMeta('rating');
  @override
  late final GeneratedColumn<double> rating = GeneratedColumn<double>(
    'rating',
    aliasedName,
    true,
    type: DriftSqlType.double,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _runtimeMsMeta = const VerificationMeta(
    'runtimeMs',
  );
  @override
  late final GeneratedColumn<int> runtimeMs = GeneratedColumn<int>(
    'runtime_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _seasonNumberMeta = const VerificationMeta(
    'seasonNumber',
  );
  @override
  late final GeneratedColumn<int> seasonNumber = GeneratedColumn<int>(
    'season_number',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _episodeNumberMeta = const VerificationMeta(
    'episodeNumber',
  );
  @override
  late final GeneratedColumn<int> episodeNumber = GeneratedColumn<int>(
    'episode_number',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _absoluteNumberMeta = const VerificationMeta(
    'absoluteNumber',
  );
  @override
  late final GeneratedColumn<int> absoluteNumber = GeneratedColumn<int>(
    'absolute_number',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _posterSourceMeta = const VerificationMeta(
    'posterSource',
  );
  @override
  late final GeneratedColumn<String> posterSource = GeneratedColumn<String>(
    'poster_source',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _backdropSourceMeta = const VerificationMeta(
    'backdropSource',
  );
  @override
  late final GeneratedColumn<String> backdropSource = GeneratedColumn<String>(
    'backdrop_source',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _logoSourceMeta = const VerificationMeta(
    'logoSource',
  );
  @override
  late final GeneratedColumn<String> logoSource = GeneratedColumn<String>(
    'logo_source',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tmdbIdMeta = const VerificationMeta('tmdbId');
  @override
  late final GeneratedColumn<String> tmdbId = GeneratedColumn<String>(
    'tmdb_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _imdbIdMeta = const VerificationMeta('imdbId');
  @override
  late final GeneratedColumn<String> imdbId = GeneratedColumn<String>(
    'imdb_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tvdbIdMeta = const VerificationMeta('tvdbId');
  @override
  late final GeneratedColumn<String> tvdbId = GeneratedColumn<String>(
    'tvdb_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _bangumiIdMeta = const VerificationMeta(
    'bangumiId',
  );
  @override
  late final GeneratedColumn<String> bangumiId = GeneratedColumn<String>(
    'bangumi_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _doubanIdMeta = const VerificationMeta(
    'doubanId',
  );
  @override
  late final GeneratedColumn<String> doubanId = GeneratedColumn<String>(
    'douban_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _metadataSourceMeta = const VerificationMeta(
    'metadataSource',
  );
  @override
  late final GeneratedColumn<String> metadataSource = GeneratedColumn<String>(
    'metadata_source',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lockedMeta = const VerificationMeta('locked');
  @override
  late final GeneratedColumn<bool> locked = GeneratedColumn<bool>(
    'locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _scrapedAtMeta = const VerificationMeta(
    'scrapedAt',
  );
  @override
  late final GeneratedColumn<int> scrapedAt = GeneratedColumn<int>(
    'scraped_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    libraryType,
    parentId,
    showId,
    title,
    sortTitle,
    originalTitle,
    aliases,
    year,
    releaseDate,
    summary,
    tagline,
    contentRating,
    studio,
    rating,
    runtimeMs,
    seasonNumber,
    episodeNumber,
    absoluteNumber,
    posterSource,
    backdropSource,
    logoSource,
    tmdbId,
    imdbId,
    tvdbId,
    bangumiId,
    doubanId,
    metadataSource,
    locked,
    addedAt,
    updatedAt,
    scrapedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('library_type')) {
      context.handle(
        _libraryTypeMeta,
        libraryType.isAcceptableOrUnknown(
          data['library_type']!,
          _libraryTypeMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_libraryTypeMeta);
    }
    if (data.containsKey('parent_id')) {
      context.handle(
        _parentIdMeta,
        parentId.isAcceptableOrUnknown(data['parent_id']!, _parentIdMeta),
      );
    }
    if (data.containsKey('show_id')) {
      context.handle(
        _showIdMeta,
        showId.isAcceptableOrUnknown(data['show_id']!, _showIdMeta),
      );
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('sort_title')) {
      context.handle(
        _sortTitleMeta,
        sortTitle.isAcceptableOrUnknown(data['sort_title']!, _sortTitleMeta),
      );
    } else if (isInserting) {
      context.missing(_sortTitleMeta);
    }
    if (data.containsKey('original_title')) {
      context.handle(
        _originalTitleMeta,
        originalTitle.isAcceptableOrUnknown(
          data['original_title']!,
          _originalTitleMeta,
        ),
      );
    }
    if (data.containsKey('aliases')) {
      context.handle(
        _aliasesMeta,
        aliases.isAcceptableOrUnknown(data['aliases']!, _aliasesMeta),
      );
    }
    if (data.containsKey('year')) {
      context.handle(
        _yearMeta,
        year.isAcceptableOrUnknown(data['year']!, _yearMeta),
      );
    }
    if (data.containsKey('release_date')) {
      context.handle(
        _releaseDateMeta,
        releaseDate.isAcceptableOrUnknown(
          data['release_date']!,
          _releaseDateMeta,
        ),
      );
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    }
    if (data.containsKey('tagline')) {
      context.handle(
        _taglineMeta,
        tagline.isAcceptableOrUnknown(data['tagline']!, _taglineMeta),
      );
    }
    if (data.containsKey('content_rating')) {
      context.handle(
        _contentRatingMeta,
        contentRating.isAcceptableOrUnknown(
          data['content_rating']!,
          _contentRatingMeta,
        ),
      );
    }
    if (data.containsKey('studio')) {
      context.handle(
        _studioMeta,
        studio.isAcceptableOrUnknown(data['studio']!, _studioMeta),
      );
    }
    if (data.containsKey('rating')) {
      context.handle(
        _ratingMeta,
        rating.isAcceptableOrUnknown(data['rating']!, _ratingMeta),
      );
    }
    if (data.containsKey('runtime_ms')) {
      context.handle(
        _runtimeMsMeta,
        runtimeMs.isAcceptableOrUnknown(data['runtime_ms']!, _runtimeMsMeta),
      );
    }
    if (data.containsKey('season_number')) {
      context.handle(
        _seasonNumberMeta,
        seasonNumber.isAcceptableOrUnknown(
          data['season_number']!,
          _seasonNumberMeta,
        ),
      );
    }
    if (data.containsKey('episode_number')) {
      context.handle(
        _episodeNumberMeta,
        episodeNumber.isAcceptableOrUnknown(
          data['episode_number']!,
          _episodeNumberMeta,
        ),
      );
    }
    if (data.containsKey('absolute_number')) {
      context.handle(
        _absoluteNumberMeta,
        absoluteNumber.isAcceptableOrUnknown(
          data['absolute_number']!,
          _absoluteNumberMeta,
        ),
      );
    }
    if (data.containsKey('poster_source')) {
      context.handle(
        _posterSourceMeta,
        posterSource.isAcceptableOrUnknown(
          data['poster_source']!,
          _posterSourceMeta,
        ),
      );
    }
    if (data.containsKey('backdrop_source')) {
      context.handle(
        _backdropSourceMeta,
        backdropSource.isAcceptableOrUnknown(
          data['backdrop_source']!,
          _backdropSourceMeta,
        ),
      );
    }
    if (data.containsKey('logo_source')) {
      context.handle(
        _logoSourceMeta,
        logoSource.isAcceptableOrUnknown(data['logo_source']!, _logoSourceMeta),
      );
    }
    if (data.containsKey('tmdb_id')) {
      context.handle(
        _tmdbIdMeta,
        tmdbId.isAcceptableOrUnknown(data['tmdb_id']!, _tmdbIdMeta),
      );
    }
    if (data.containsKey('imdb_id')) {
      context.handle(
        _imdbIdMeta,
        imdbId.isAcceptableOrUnknown(data['imdb_id']!, _imdbIdMeta),
      );
    }
    if (data.containsKey('tvdb_id')) {
      context.handle(
        _tvdbIdMeta,
        tvdbId.isAcceptableOrUnknown(data['tvdb_id']!, _tvdbIdMeta),
      );
    }
    if (data.containsKey('bangumi_id')) {
      context.handle(
        _bangumiIdMeta,
        bangumiId.isAcceptableOrUnknown(data['bangumi_id']!, _bangumiIdMeta),
      );
    }
    if (data.containsKey('douban_id')) {
      context.handle(
        _doubanIdMeta,
        doubanId.isAcceptableOrUnknown(data['douban_id']!, _doubanIdMeta),
      );
    }
    if (data.containsKey('metadata_source')) {
      context.handle(
        _metadataSourceMeta,
        metadataSource.isAcceptableOrUnknown(
          data['metadata_source']!,
          _metadataSourceMeta,
        ),
      );
    }
    if (data.containsKey('locked')) {
      context.handle(
        _lockedMeta,
        locked.isAcceptableOrUnknown(data['locked']!, _lockedMeta),
      );
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('scraped_at')) {
      context.handle(
        _scrapedAtMeta,
        scrapedAt.isAcceptableOrUnknown(data['scraped_at']!, _scrapedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LibraryItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryItemRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      libraryType: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}library_type'],
      )!,
      parentId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}parent_id'],
      ),
      showId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}show_id'],
      ),
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      sortTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}sort_title'],
      )!,
      originalTitle: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}original_title'],
      ),
      aliases: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}aliases'],
      ),
      year: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}year'],
      ),
      releaseDate: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}release_date'],
      ),
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      ),
      tagline: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tagline'],
      ),
      contentRating: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}content_rating'],
      ),
      studio: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}studio'],
      ),
      rating: attachedDatabase.typeMapping.read(
        DriftSqlType.double,
        data['${effectivePrefix}rating'],
      ),
      runtimeMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}runtime_ms'],
      ),
      seasonNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}season_number'],
      ),
      episodeNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}episode_number'],
      ),
      absoluteNumber: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}absolute_number'],
      ),
      posterSource: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poster_source'],
      ),
      backdropSource: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}backdrop_source'],
      ),
      logoSource: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}logo_source'],
      ),
      tmdbId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tmdb_id'],
      ),
      imdbId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}imdb_id'],
      ),
      tvdbId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tvdb_id'],
      ),
      bangumiId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}bangumi_id'],
      ),
      doubanId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}douban_id'],
      ),
      metadataSource: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}metadata_source'],
      ),
      locked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}locked'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}added_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
      scrapedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}scraped_at'],
      ),
    );
  }

  @override
  $LibraryItemsTable createAlias(String alias) {
    return $LibraryItemsTable(attachedDatabase, alias);
  }
}

class LibraryItemRow extends DataClass implements Insertable<LibraryItemRow> {
  final int id;

  /// `'movie'`, `'show'`, `'season'` or `'episode'`.
  final String kind;

  /// Which library the title is shelved in: `'movie'`, `'show'` or `'anime'`.
  /// Children carry their show's value.
  final String libraryType;
  final int? parentId;
  final int? showId;
  final String title;

  /// Lower-cased title with leading articles removed, for ordering.
  final String sortTitle;
  final String? originalTitle;

  /// Other names the title is known by, newline-separated, for search.
  final String? aliases;
  final int? year;

  /// First release or air date as `YYYY-MM-DD`.
  final String? releaseDate;
  final String? summary;
  final String? tagline;
  final String? contentRating;
  final String? studio;

  /// Community score on a 0–10 scale.
  final double? rating;
  final int? runtimeMs;

  /// Season number for seasons and episodes; 0 is specials.
  final int? seasonNumber;
  final int? episodeNumber;

  /// Running episode count across seasons, as anime releases number them.
  final int? absoluteNumber;

  /// Artwork sources: a remote URL, or `mount:<mountId>:<path>` for an image
  /// found next to the media.
  final String? posterSource;
  final String? backdropSource;
  final String? logoSource;
  final String? tmdbId;
  final String? imdbId;
  final String? tvdbId;
  final String? bangumiId;
  final String? doubanId;

  /// Which scraper filled this row: `'nfo'`, `'tmdb'`, `'bangumi'`, …
  /// Null while the row only holds what the file name gave away.
  final String? metadataSource;

  /// True once the user matched or edited the title by hand; scrapers and
  /// rescans then leave it alone.
  final bool locked;
  final int addedAt;
  final int updatedAt;
  final int? scrapedAt;
  const LibraryItemRow({
    required this.id,
    required this.kind,
    required this.libraryType,
    this.parentId,
    this.showId,
    required this.title,
    required this.sortTitle,
    this.originalTitle,
    this.aliases,
    this.year,
    this.releaseDate,
    this.summary,
    this.tagline,
    this.contentRating,
    this.studio,
    this.rating,
    this.runtimeMs,
    this.seasonNumber,
    this.episodeNumber,
    this.absoluteNumber,
    this.posterSource,
    this.backdropSource,
    this.logoSource,
    this.tmdbId,
    this.imdbId,
    this.tvdbId,
    this.bangumiId,
    this.doubanId,
    this.metadataSource,
    required this.locked,
    required this.addedAt,
    required this.updatedAt,
    this.scrapedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['kind'] = Variable<String>(kind);
    map['library_type'] = Variable<String>(libraryType);
    if (!nullToAbsent || parentId != null) {
      map['parent_id'] = Variable<int>(parentId);
    }
    if (!nullToAbsent || showId != null) {
      map['show_id'] = Variable<int>(showId);
    }
    map['title'] = Variable<String>(title);
    map['sort_title'] = Variable<String>(sortTitle);
    if (!nullToAbsent || originalTitle != null) {
      map['original_title'] = Variable<String>(originalTitle);
    }
    if (!nullToAbsent || aliases != null) {
      map['aliases'] = Variable<String>(aliases);
    }
    if (!nullToAbsent || year != null) {
      map['year'] = Variable<int>(year);
    }
    if (!nullToAbsent || releaseDate != null) {
      map['release_date'] = Variable<String>(releaseDate);
    }
    if (!nullToAbsent || summary != null) {
      map['summary'] = Variable<String>(summary);
    }
    if (!nullToAbsent || tagline != null) {
      map['tagline'] = Variable<String>(tagline);
    }
    if (!nullToAbsent || contentRating != null) {
      map['content_rating'] = Variable<String>(contentRating);
    }
    if (!nullToAbsent || studio != null) {
      map['studio'] = Variable<String>(studio);
    }
    if (!nullToAbsent || rating != null) {
      map['rating'] = Variable<double>(rating);
    }
    if (!nullToAbsent || runtimeMs != null) {
      map['runtime_ms'] = Variable<int>(runtimeMs);
    }
    if (!nullToAbsent || seasonNumber != null) {
      map['season_number'] = Variable<int>(seasonNumber);
    }
    if (!nullToAbsent || episodeNumber != null) {
      map['episode_number'] = Variable<int>(episodeNumber);
    }
    if (!nullToAbsent || absoluteNumber != null) {
      map['absolute_number'] = Variable<int>(absoluteNumber);
    }
    if (!nullToAbsent || posterSource != null) {
      map['poster_source'] = Variable<String>(posterSource);
    }
    if (!nullToAbsent || backdropSource != null) {
      map['backdrop_source'] = Variable<String>(backdropSource);
    }
    if (!nullToAbsent || logoSource != null) {
      map['logo_source'] = Variable<String>(logoSource);
    }
    if (!nullToAbsent || tmdbId != null) {
      map['tmdb_id'] = Variable<String>(tmdbId);
    }
    if (!nullToAbsent || imdbId != null) {
      map['imdb_id'] = Variable<String>(imdbId);
    }
    if (!nullToAbsent || tvdbId != null) {
      map['tvdb_id'] = Variable<String>(tvdbId);
    }
    if (!nullToAbsent || bangumiId != null) {
      map['bangumi_id'] = Variable<String>(bangumiId);
    }
    if (!nullToAbsent || doubanId != null) {
      map['douban_id'] = Variable<String>(doubanId);
    }
    if (!nullToAbsent || metadataSource != null) {
      map['metadata_source'] = Variable<String>(metadataSource);
    }
    map['locked'] = Variable<bool>(locked);
    map['added_at'] = Variable<int>(addedAt);
    map['updated_at'] = Variable<int>(updatedAt);
    if (!nullToAbsent || scrapedAt != null) {
      map['scraped_at'] = Variable<int>(scrapedAt);
    }
    return map;
  }

  LibraryItemsCompanion toCompanion(bool nullToAbsent) {
    return LibraryItemsCompanion(
      id: Value(id),
      kind: Value(kind),
      libraryType: Value(libraryType),
      parentId: parentId == null && nullToAbsent
          ? const Value.absent()
          : Value(parentId),
      showId: showId == null && nullToAbsent
          ? const Value.absent()
          : Value(showId),
      title: Value(title),
      sortTitle: Value(sortTitle),
      originalTitle: originalTitle == null && nullToAbsent
          ? const Value.absent()
          : Value(originalTitle),
      aliases: aliases == null && nullToAbsent
          ? const Value.absent()
          : Value(aliases),
      year: year == null && nullToAbsent ? const Value.absent() : Value(year),
      releaseDate: releaseDate == null && nullToAbsent
          ? const Value.absent()
          : Value(releaseDate),
      summary: summary == null && nullToAbsent
          ? const Value.absent()
          : Value(summary),
      tagline: tagline == null && nullToAbsent
          ? const Value.absent()
          : Value(tagline),
      contentRating: contentRating == null && nullToAbsent
          ? const Value.absent()
          : Value(contentRating),
      studio: studio == null && nullToAbsent
          ? const Value.absent()
          : Value(studio),
      rating: rating == null && nullToAbsent
          ? const Value.absent()
          : Value(rating),
      runtimeMs: runtimeMs == null && nullToAbsent
          ? const Value.absent()
          : Value(runtimeMs),
      seasonNumber: seasonNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(seasonNumber),
      episodeNumber: episodeNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(episodeNumber),
      absoluteNumber: absoluteNumber == null && nullToAbsent
          ? const Value.absent()
          : Value(absoluteNumber),
      posterSource: posterSource == null && nullToAbsent
          ? const Value.absent()
          : Value(posterSource),
      backdropSource: backdropSource == null && nullToAbsent
          ? const Value.absent()
          : Value(backdropSource),
      logoSource: logoSource == null && nullToAbsent
          ? const Value.absent()
          : Value(logoSource),
      tmdbId: tmdbId == null && nullToAbsent
          ? const Value.absent()
          : Value(tmdbId),
      imdbId: imdbId == null && nullToAbsent
          ? const Value.absent()
          : Value(imdbId),
      tvdbId: tvdbId == null && nullToAbsent
          ? const Value.absent()
          : Value(tvdbId),
      bangumiId: bangumiId == null && nullToAbsent
          ? const Value.absent()
          : Value(bangumiId),
      doubanId: doubanId == null && nullToAbsent
          ? const Value.absent()
          : Value(doubanId),
      metadataSource: metadataSource == null && nullToAbsent
          ? const Value.absent()
          : Value(metadataSource),
      locked: Value(locked),
      addedAt: Value(addedAt),
      updatedAt: Value(updatedAt),
      scrapedAt: scrapedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(scrapedAt),
    );
  }

  factory LibraryItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryItemRow(
      id: serializer.fromJson<int>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      libraryType: serializer.fromJson<String>(json['libraryType']),
      parentId: serializer.fromJson<int?>(json['parentId']),
      showId: serializer.fromJson<int?>(json['showId']),
      title: serializer.fromJson<String>(json['title']),
      sortTitle: serializer.fromJson<String>(json['sortTitle']),
      originalTitle: serializer.fromJson<String?>(json['originalTitle']),
      aliases: serializer.fromJson<String?>(json['aliases']),
      year: serializer.fromJson<int?>(json['year']),
      releaseDate: serializer.fromJson<String?>(json['releaseDate']),
      summary: serializer.fromJson<String?>(json['summary']),
      tagline: serializer.fromJson<String?>(json['tagline']),
      contentRating: serializer.fromJson<String?>(json['contentRating']),
      studio: serializer.fromJson<String?>(json['studio']),
      rating: serializer.fromJson<double?>(json['rating']),
      runtimeMs: serializer.fromJson<int?>(json['runtimeMs']),
      seasonNumber: serializer.fromJson<int?>(json['seasonNumber']),
      episodeNumber: serializer.fromJson<int?>(json['episodeNumber']),
      absoluteNumber: serializer.fromJson<int?>(json['absoluteNumber']),
      posterSource: serializer.fromJson<String?>(json['posterSource']),
      backdropSource: serializer.fromJson<String?>(json['backdropSource']),
      logoSource: serializer.fromJson<String?>(json['logoSource']),
      tmdbId: serializer.fromJson<String?>(json['tmdbId']),
      imdbId: serializer.fromJson<String?>(json['imdbId']),
      tvdbId: serializer.fromJson<String?>(json['tvdbId']),
      bangumiId: serializer.fromJson<String?>(json['bangumiId']),
      doubanId: serializer.fromJson<String?>(json['doubanId']),
      metadataSource: serializer.fromJson<String?>(json['metadataSource']),
      locked: serializer.fromJson<bool>(json['locked']),
      addedAt: serializer.fromJson<int>(json['addedAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
      scrapedAt: serializer.fromJson<int?>(json['scrapedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'kind': serializer.toJson<String>(kind),
      'libraryType': serializer.toJson<String>(libraryType),
      'parentId': serializer.toJson<int?>(parentId),
      'showId': serializer.toJson<int?>(showId),
      'title': serializer.toJson<String>(title),
      'sortTitle': serializer.toJson<String>(sortTitle),
      'originalTitle': serializer.toJson<String?>(originalTitle),
      'aliases': serializer.toJson<String?>(aliases),
      'year': serializer.toJson<int?>(year),
      'releaseDate': serializer.toJson<String?>(releaseDate),
      'summary': serializer.toJson<String?>(summary),
      'tagline': serializer.toJson<String?>(tagline),
      'contentRating': serializer.toJson<String?>(contentRating),
      'studio': serializer.toJson<String?>(studio),
      'rating': serializer.toJson<double?>(rating),
      'runtimeMs': serializer.toJson<int?>(runtimeMs),
      'seasonNumber': serializer.toJson<int?>(seasonNumber),
      'episodeNumber': serializer.toJson<int?>(episodeNumber),
      'absoluteNumber': serializer.toJson<int?>(absoluteNumber),
      'posterSource': serializer.toJson<String?>(posterSource),
      'backdropSource': serializer.toJson<String?>(backdropSource),
      'logoSource': serializer.toJson<String?>(logoSource),
      'tmdbId': serializer.toJson<String?>(tmdbId),
      'imdbId': serializer.toJson<String?>(imdbId),
      'tvdbId': serializer.toJson<String?>(tvdbId),
      'bangumiId': serializer.toJson<String?>(bangumiId),
      'doubanId': serializer.toJson<String?>(doubanId),
      'metadataSource': serializer.toJson<String?>(metadataSource),
      'locked': serializer.toJson<bool>(locked),
      'addedAt': serializer.toJson<int>(addedAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
      'scrapedAt': serializer.toJson<int?>(scrapedAt),
    };
  }

  LibraryItemRow copyWith({
    int? id,
    String? kind,
    String? libraryType,
    Value<int?> parentId = const Value.absent(),
    Value<int?> showId = const Value.absent(),
    String? title,
    String? sortTitle,
    Value<String?> originalTitle = const Value.absent(),
    Value<String?> aliases = const Value.absent(),
    Value<int?> year = const Value.absent(),
    Value<String?> releaseDate = const Value.absent(),
    Value<String?> summary = const Value.absent(),
    Value<String?> tagline = const Value.absent(),
    Value<String?> contentRating = const Value.absent(),
    Value<String?> studio = const Value.absent(),
    Value<double?> rating = const Value.absent(),
    Value<int?> runtimeMs = const Value.absent(),
    Value<int?> seasonNumber = const Value.absent(),
    Value<int?> episodeNumber = const Value.absent(),
    Value<int?> absoluteNumber = const Value.absent(),
    Value<String?> posterSource = const Value.absent(),
    Value<String?> backdropSource = const Value.absent(),
    Value<String?> logoSource = const Value.absent(),
    Value<String?> tmdbId = const Value.absent(),
    Value<String?> imdbId = const Value.absent(),
    Value<String?> tvdbId = const Value.absent(),
    Value<String?> bangumiId = const Value.absent(),
    Value<String?> doubanId = const Value.absent(),
    Value<String?> metadataSource = const Value.absent(),
    bool? locked,
    int? addedAt,
    int? updatedAt,
    Value<int?> scrapedAt = const Value.absent(),
  }) => LibraryItemRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    libraryType: libraryType ?? this.libraryType,
    parentId: parentId.present ? parentId.value : this.parentId,
    showId: showId.present ? showId.value : this.showId,
    title: title ?? this.title,
    sortTitle: sortTitle ?? this.sortTitle,
    originalTitle: originalTitle.present
        ? originalTitle.value
        : this.originalTitle,
    aliases: aliases.present ? aliases.value : this.aliases,
    year: year.present ? year.value : this.year,
    releaseDate: releaseDate.present ? releaseDate.value : this.releaseDate,
    summary: summary.present ? summary.value : this.summary,
    tagline: tagline.present ? tagline.value : this.tagline,
    contentRating: contentRating.present
        ? contentRating.value
        : this.contentRating,
    studio: studio.present ? studio.value : this.studio,
    rating: rating.present ? rating.value : this.rating,
    runtimeMs: runtimeMs.present ? runtimeMs.value : this.runtimeMs,
    seasonNumber: seasonNumber.present ? seasonNumber.value : this.seasonNumber,
    episodeNumber: episodeNumber.present
        ? episodeNumber.value
        : this.episodeNumber,
    absoluteNumber: absoluteNumber.present
        ? absoluteNumber.value
        : this.absoluteNumber,
    posterSource: posterSource.present ? posterSource.value : this.posterSource,
    backdropSource: backdropSource.present
        ? backdropSource.value
        : this.backdropSource,
    logoSource: logoSource.present ? logoSource.value : this.logoSource,
    tmdbId: tmdbId.present ? tmdbId.value : this.tmdbId,
    imdbId: imdbId.present ? imdbId.value : this.imdbId,
    tvdbId: tvdbId.present ? tvdbId.value : this.tvdbId,
    bangumiId: bangumiId.present ? bangumiId.value : this.bangumiId,
    doubanId: doubanId.present ? doubanId.value : this.doubanId,
    metadataSource: metadataSource.present
        ? metadataSource.value
        : this.metadataSource,
    locked: locked ?? this.locked,
    addedAt: addedAt ?? this.addedAt,
    updatedAt: updatedAt ?? this.updatedAt,
    scrapedAt: scrapedAt.present ? scrapedAt.value : this.scrapedAt,
  );
  LibraryItemRow copyWithCompanion(LibraryItemsCompanion data) {
    return LibraryItemRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      libraryType: data.libraryType.present
          ? data.libraryType.value
          : this.libraryType,
      parentId: data.parentId.present ? data.parentId.value : this.parentId,
      showId: data.showId.present ? data.showId.value : this.showId,
      title: data.title.present ? data.title.value : this.title,
      sortTitle: data.sortTitle.present ? data.sortTitle.value : this.sortTitle,
      originalTitle: data.originalTitle.present
          ? data.originalTitle.value
          : this.originalTitle,
      aliases: data.aliases.present ? data.aliases.value : this.aliases,
      year: data.year.present ? data.year.value : this.year,
      releaseDate: data.releaseDate.present
          ? data.releaseDate.value
          : this.releaseDate,
      summary: data.summary.present ? data.summary.value : this.summary,
      tagline: data.tagline.present ? data.tagline.value : this.tagline,
      contentRating: data.contentRating.present
          ? data.contentRating.value
          : this.contentRating,
      studio: data.studio.present ? data.studio.value : this.studio,
      rating: data.rating.present ? data.rating.value : this.rating,
      runtimeMs: data.runtimeMs.present ? data.runtimeMs.value : this.runtimeMs,
      seasonNumber: data.seasonNumber.present
          ? data.seasonNumber.value
          : this.seasonNumber,
      episodeNumber: data.episodeNumber.present
          ? data.episodeNumber.value
          : this.episodeNumber,
      absoluteNumber: data.absoluteNumber.present
          ? data.absoluteNumber.value
          : this.absoluteNumber,
      posterSource: data.posterSource.present
          ? data.posterSource.value
          : this.posterSource,
      backdropSource: data.backdropSource.present
          ? data.backdropSource.value
          : this.backdropSource,
      logoSource: data.logoSource.present
          ? data.logoSource.value
          : this.logoSource,
      tmdbId: data.tmdbId.present ? data.tmdbId.value : this.tmdbId,
      imdbId: data.imdbId.present ? data.imdbId.value : this.imdbId,
      tvdbId: data.tvdbId.present ? data.tvdbId.value : this.tvdbId,
      bangumiId: data.bangumiId.present ? data.bangumiId.value : this.bangumiId,
      doubanId: data.doubanId.present ? data.doubanId.value : this.doubanId,
      metadataSource: data.metadataSource.present
          ? data.metadataSource.value
          : this.metadataSource,
      locked: data.locked.present ? data.locked.value : this.locked,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      scrapedAt: data.scrapedAt.present ? data.scrapedAt.value : this.scrapedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryItemRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('libraryType: $libraryType, ')
          ..write('parentId: $parentId, ')
          ..write('showId: $showId, ')
          ..write('title: $title, ')
          ..write('sortTitle: $sortTitle, ')
          ..write('originalTitle: $originalTitle, ')
          ..write('aliases: $aliases, ')
          ..write('year: $year, ')
          ..write('releaseDate: $releaseDate, ')
          ..write('summary: $summary, ')
          ..write('tagline: $tagline, ')
          ..write('contentRating: $contentRating, ')
          ..write('studio: $studio, ')
          ..write('rating: $rating, ')
          ..write('runtimeMs: $runtimeMs, ')
          ..write('seasonNumber: $seasonNumber, ')
          ..write('episodeNumber: $episodeNumber, ')
          ..write('absoluteNumber: $absoluteNumber, ')
          ..write('posterSource: $posterSource, ')
          ..write('backdropSource: $backdropSource, ')
          ..write('logoSource: $logoSource, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('imdbId: $imdbId, ')
          ..write('tvdbId: $tvdbId, ')
          ..write('bangumiId: $bangumiId, ')
          ..write('doubanId: $doubanId, ')
          ..write('metadataSource: $metadataSource, ')
          ..write('locked: $locked, ')
          ..write('addedAt: $addedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('scrapedAt: $scrapedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    kind,
    libraryType,
    parentId,
    showId,
    title,
    sortTitle,
    originalTitle,
    aliases,
    year,
    releaseDate,
    summary,
    tagline,
    contentRating,
    studio,
    rating,
    runtimeMs,
    seasonNumber,
    episodeNumber,
    absoluteNumber,
    posterSource,
    backdropSource,
    logoSource,
    tmdbId,
    imdbId,
    tvdbId,
    bangumiId,
    doubanId,
    metadataSource,
    locked,
    addedAt,
    updatedAt,
    scrapedAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryItemRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.libraryType == this.libraryType &&
          other.parentId == this.parentId &&
          other.showId == this.showId &&
          other.title == this.title &&
          other.sortTitle == this.sortTitle &&
          other.originalTitle == this.originalTitle &&
          other.aliases == this.aliases &&
          other.year == this.year &&
          other.releaseDate == this.releaseDate &&
          other.summary == this.summary &&
          other.tagline == this.tagline &&
          other.contentRating == this.contentRating &&
          other.studio == this.studio &&
          other.rating == this.rating &&
          other.runtimeMs == this.runtimeMs &&
          other.seasonNumber == this.seasonNumber &&
          other.episodeNumber == this.episodeNumber &&
          other.absoluteNumber == this.absoluteNumber &&
          other.posterSource == this.posterSource &&
          other.backdropSource == this.backdropSource &&
          other.logoSource == this.logoSource &&
          other.tmdbId == this.tmdbId &&
          other.imdbId == this.imdbId &&
          other.tvdbId == this.tvdbId &&
          other.bangumiId == this.bangumiId &&
          other.doubanId == this.doubanId &&
          other.metadataSource == this.metadataSource &&
          other.locked == this.locked &&
          other.addedAt == this.addedAt &&
          other.updatedAt == this.updatedAt &&
          other.scrapedAt == this.scrapedAt);
}

class LibraryItemsCompanion extends UpdateCompanion<LibraryItemRow> {
  final Value<int> id;
  final Value<String> kind;
  final Value<String> libraryType;
  final Value<int?> parentId;
  final Value<int?> showId;
  final Value<String> title;
  final Value<String> sortTitle;
  final Value<String?> originalTitle;
  final Value<String?> aliases;
  final Value<int?> year;
  final Value<String?> releaseDate;
  final Value<String?> summary;
  final Value<String?> tagline;
  final Value<String?> contentRating;
  final Value<String?> studio;
  final Value<double?> rating;
  final Value<int?> runtimeMs;
  final Value<int?> seasonNumber;
  final Value<int?> episodeNumber;
  final Value<int?> absoluteNumber;
  final Value<String?> posterSource;
  final Value<String?> backdropSource;
  final Value<String?> logoSource;
  final Value<String?> tmdbId;
  final Value<String?> imdbId;
  final Value<String?> tvdbId;
  final Value<String?> bangumiId;
  final Value<String?> doubanId;
  final Value<String?> metadataSource;
  final Value<bool> locked;
  final Value<int> addedAt;
  final Value<int> updatedAt;
  final Value<int?> scrapedAt;
  const LibraryItemsCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.libraryType = const Value.absent(),
    this.parentId = const Value.absent(),
    this.showId = const Value.absent(),
    this.title = const Value.absent(),
    this.sortTitle = const Value.absent(),
    this.originalTitle = const Value.absent(),
    this.aliases = const Value.absent(),
    this.year = const Value.absent(),
    this.releaseDate = const Value.absent(),
    this.summary = const Value.absent(),
    this.tagline = const Value.absent(),
    this.contentRating = const Value.absent(),
    this.studio = const Value.absent(),
    this.rating = const Value.absent(),
    this.runtimeMs = const Value.absent(),
    this.seasonNumber = const Value.absent(),
    this.episodeNumber = const Value.absent(),
    this.absoluteNumber = const Value.absent(),
    this.posterSource = const Value.absent(),
    this.backdropSource = const Value.absent(),
    this.logoSource = const Value.absent(),
    this.tmdbId = const Value.absent(),
    this.imdbId = const Value.absent(),
    this.tvdbId = const Value.absent(),
    this.bangumiId = const Value.absent(),
    this.doubanId = const Value.absent(),
    this.metadataSource = const Value.absent(),
    this.locked = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.scrapedAt = const Value.absent(),
  });
  LibraryItemsCompanion.insert({
    this.id = const Value.absent(),
    required String kind,
    required String libraryType,
    this.parentId = const Value.absent(),
    this.showId = const Value.absent(),
    required String title,
    required String sortTitle,
    this.originalTitle = const Value.absent(),
    this.aliases = const Value.absent(),
    this.year = const Value.absent(),
    this.releaseDate = const Value.absent(),
    this.summary = const Value.absent(),
    this.tagline = const Value.absent(),
    this.contentRating = const Value.absent(),
    this.studio = const Value.absent(),
    this.rating = const Value.absent(),
    this.runtimeMs = const Value.absent(),
    this.seasonNumber = const Value.absent(),
    this.episodeNumber = const Value.absent(),
    this.absoluteNumber = const Value.absent(),
    this.posterSource = const Value.absent(),
    this.backdropSource = const Value.absent(),
    this.logoSource = const Value.absent(),
    this.tmdbId = const Value.absent(),
    this.imdbId = const Value.absent(),
    this.tvdbId = const Value.absent(),
    this.bangumiId = const Value.absent(),
    this.doubanId = const Value.absent(),
    this.metadataSource = const Value.absent(),
    this.locked = const Value.absent(),
    required int addedAt,
    required int updatedAt,
    this.scrapedAt = const Value.absent(),
  }) : kind = Value(kind),
       libraryType = Value(libraryType),
       title = Value(title),
       sortTitle = Value(sortTitle),
       addedAt = Value(addedAt),
       updatedAt = Value(updatedAt);
  static Insertable<LibraryItemRow> custom({
    Expression<int>? id,
    Expression<String>? kind,
    Expression<String>? libraryType,
    Expression<int>? parentId,
    Expression<int>? showId,
    Expression<String>? title,
    Expression<String>? sortTitle,
    Expression<String>? originalTitle,
    Expression<String>? aliases,
    Expression<int>? year,
    Expression<String>? releaseDate,
    Expression<String>? summary,
    Expression<String>? tagline,
    Expression<String>? contentRating,
    Expression<String>? studio,
    Expression<double>? rating,
    Expression<int>? runtimeMs,
    Expression<int>? seasonNumber,
    Expression<int>? episodeNumber,
    Expression<int>? absoluteNumber,
    Expression<String>? posterSource,
    Expression<String>? backdropSource,
    Expression<String>? logoSource,
    Expression<String>? tmdbId,
    Expression<String>? imdbId,
    Expression<String>? tvdbId,
    Expression<String>? bangumiId,
    Expression<String>? doubanId,
    Expression<String>? metadataSource,
    Expression<bool>? locked,
    Expression<int>? addedAt,
    Expression<int>? updatedAt,
    Expression<int>? scrapedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (libraryType != null) 'library_type': libraryType,
      if (parentId != null) 'parent_id': parentId,
      if (showId != null) 'show_id': showId,
      if (title != null) 'title': title,
      if (sortTitle != null) 'sort_title': sortTitle,
      if (originalTitle != null) 'original_title': originalTitle,
      if (aliases != null) 'aliases': aliases,
      if (year != null) 'year': year,
      if (releaseDate != null) 'release_date': releaseDate,
      if (summary != null) 'summary': summary,
      if (tagline != null) 'tagline': tagline,
      if (contentRating != null) 'content_rating': contentRating,
      if (studio != null) 'studio': studio,
      if (rating != null) 'rating': rating,
      if (runtimeMs != null) 'runtime_ms': runtimeMs,
      if (seasonNumber != null) 'season_number': seasonNumber,
      if (episodeNumber != null) 'episode_number': episodeNumber,
      if (absoluteNumber != null) 'absolute_number': absoluteNumber,
      if (posterSource != null) 'poster_source': posterSource,
      if (backdropSource != null) 'backdrop_source': backdropSource,
      if (logoSource != null) 'logo_source': logoSource,
      if (tmdbId != null) 'tmdb_id': tmdbId,
      if (imdbId != null) 'imdb_id': imdbId,
      if (tvdbId != null) 'tvdb_id': tvdbId,
      if (bangumiId != null) 'bangumi_id': bangumiId,
      if (doubanId != null) 'douban_id': doubanId,
      if (metadataSource != null) 'metadata_source': metadataSource,
      if (locked != null) 'locked': locked,
      if (addedAt != null) 'added_at': addedAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (scrapedAt != null) 'scraped_at': scrapedAt,
    });
  }

  LibraryItemsCompanion copyWith({
    Value<int>? id,
    Value<String>? kind,
    Value<String>? libraryType,
    Value<int?>? parentId,
    Value<int?>? showId,
    Value<String>? title,
    Value<String>? sortTitle,
    Value<String?>? originalTitle,
    Value<String?>? aliases,
    Value<int?>? year,
    Value<String?>? releaseDate,
    Value<String?>? summary,
    Value<String?>? tagline,
    Value<String?>? contentRating,
    Value<String?>? studio,
    Value<double?>? rating,
    Value<int?>? runtimeMs,
    Value<int?>? seasonNumber,
    Value<int?>? episodeNumber,
    Value<int?>? absoluteNumber,
    Value<String?>? posterSource,
    Value<String?>? backdropSource,
    Value<String?>? logoSource,
    Value<String?>? tmdbId,
    Value<String?>? imdbId,
    Value<String?>? tvdbId,
    Value<String?>? bangumiId,
    Value<String?>? doubanId,
    Value<String?>? metadataSource,
    Value<bool>? locked,
    Value<int>? addedAt,
    Value<int>? updatedAt,
    Value<int?>? scrapedAt,
  }) {
    return LibraryItemsCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      libraryType: libraryType ?? this.libraryType,
      parentId: parentId ?? this.parentId,
      showId: showId ?? this.showId,
      title: title ?? this.title,
      sortTitle: sortTitle ?? this.sortTitle,
      originalTitle: originalTitle ?? this.originalTitle,
      aliases: aliases ?? this.aliases,
      year: year ?? this.year,
      releaseDate: releaseDate ?? this.releaseDate,
      summary: summary ?? this.summary,
      tagline: tagline ?? this.tagline,
      contentRating: contentRating ?? this.contentRating,
      studio: studio ?? this.studio,
      rating: rating ?? this.rating,
      runtimeMs: runtimeMs ?? this.runtimeMs,
      seasonNumber: seasonNumber ?? this.seasonNumber,
      episodeNumber: episodeNumber ?? this.episodeNumber,
      absoluteNumber: absoluteNumber ?? this.absoluteNumber,
      posterSource: posterSource ?? this.posterSource,
      backdropSource: backdropSource ?? this.backdropSource,
      logoSource: logoSource ?? this.logoSource,
      tmdbId: tmdbId ?? this.tmdbId,
      imdbId: imdbId ?? this.imdbId,
      tvdbId: tvdbId ?? this.tvdbId,
      bangumiId: bangumiId ?? this.bangumiId,
      doubanId: doubanId ?? this.doubanId,
      metadataSource: metadataSource ?? this.metadataSource,
      locked: locked ?? this.locked,
      addedAt: addedAt ?? this.addedAt,
      updatedAt: updatedAt ?? this.updatedAt,
      scrapedAt: scrapedAt ?? this.scrapedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (libraryType.present) {
      map['library_type'] = Variable<String>(libraryType.value);
    }
    if (parentId.present) {
      map['parent_id'] = Variable<int>(parentId.value);
    }
    if (showId.present) {
      map['show_id'] = Variable<int>(showId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (sortTitle.present) {
      map['sort_title'] = Variable<String>(sortTitle.value);
    }
    if (originalTitle.present) {
      map['original_title'] = Variable<String>(originalTitle.value);
    }
    if (aliases.present) {
      map['aliases'] = Variable<String>(aliases.value);
    }
    if (year.present) {
      map['year'] = Variable<int>(year.value);
    }
    if (releaseDate.present) {
      map['release_date'] = Variable<String>(releaseDate.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (tagline.present) {
      map['tagline'] = Variable<String>(tagline.value);
    }
    if (contentRating.present) {
      map['content_rating'] = Variable<String>(contentRating.value);
    }
    if (studio.present) {
      map['studio'] = Variable<String>(studio.value);
    }
    if (rating.present) {
      map['rating'] = Variable<double>(rating.value);
    }
    if (runtimeMs.present) {
      map['runtime_ms'] = Variable<int>(runtimeMs.value);
    }
    if (seasonNumber.present) {
      map['season_number'] = Variable<int>(seasonNumber.value);
    }
    if (episodeNumber.present) {
      map['episode_number'] = Variable<int>(episodeNumber.value);
    }
    if (absoluteNumber.present) {
      map['absolute_number'] = Variable<int>(absoluteNumber.value);
    }
    if (posterSource.present) {
      map['poster_source'] = Variable<String>(posterSource.value);
    }
    if (backdropSource.present) {
      map['backdrop_source'] = Variable<String>(backdropSource.value);
    }
    if (logoSource.present) {
      map['logo_source'] = Variable<String>(logoSource.value);
    }
    if (tmdbId.present) {
      map['tmdb_id'] = Variable<String>(tmdbId.value);
    }
    if (imdbId.present) {
      map['imdb_id'] = Variable<String>(imdbId.value);
    }
    if (tvdbId.present) {
      map['tvdb_id'] = Variable<String>(tvdbId.value);
    }
    if (bangumiId.present) {
      map['bangumi_id'] = Variable<String>(bangumiId.value);
    }
    if (doubanId.present) {
      map['douban_id'] = Variable<String>(doubanId.value);
    }
    if (metadataSource.present) {
      map['metadata_source'] = Variable<String>(metadataSource.value);
    }
    if (locked.present) {
      map['locked'] = Variable<bool>(locked.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<int>(addedAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    if (scrapedAt.present) {
      map['scraped_at'] = Variable<int>(scrapedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryItemsCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('libraryType: $libraryType, ')
          ..write('parentId: $parentId, ')
          ..write('showId: $showId, ')
          ..write('title: $title, ')
          ..write('sortTitle: $sortTitle, ')
          ..write('originalTitle: $originalTitle, ')
          ..write('aliases: $aliases, ')
          ..write('year: $year, ')
          ..write('releaseDate: $releaseDate, ')
          ..write('summary: $summary, ')
          ..write('tagline: $tagline, ')
          ..write('contentRating: $contentRating, ')
          ..write('studio: $studio, ')
          ..write('rating: $rating, ')
          ..write('runtimeMs: $runtimeMs, ')
          ..write('seasonNumber: $seasonNumber, ')
          ..write('episodeNumber: $episodeNumber, ')
          ..write('absoluteNumber: $absoluteNumber, ')
          ..write('posterSource: $posterSource, ')
          ..write('backdropSource: $backdropSource, ')
          ..write('logoSource: $logoSource, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('imdbId: $imdbId, ')
          ..write('tvdbId: $tvdbId, ')
          ..write('bangumiId: $bangumiId, ')
          ..write('doubanId: $doubanId, ')
          ..write('metadataSource: $metadataSource, ')
          ..write('locked: $locked, ')
          ..write('addedAt: $addedAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('scrapedAt: $scrapedAt')
          ..write(')'))
        .toString();
  }
}

class $LibraryFilesTable extends LibraryFiles
    with TableInfo<$LibraryFilesTable, LibraryFileRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryFilesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _mountIdMeta = const VerificationMeta(
    'mountId',
  );
  @override
  late final GeneratedColumn<String> mountId = GeneratedColumn<String>(
    'mount_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES mounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _pathMeta = const VerificationMeta('path');
  @override
  late final GeneratedColumn<String> path = GeneratedColumn<String>(
    'path',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _remoteIdMeta = const VerificationMeta(
    'remoteId',
  );
  @override
  late final GeneratedColumn<String> remoteId = GeneratedColumn<String>(
    'remote_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sizeMeta = const VerificationMeta('size');
  @override
  late final GeneratedColumn<int> size = GeneratedColumn<int>(
    'size',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _modifiedAtMeta = const VerificationMeta(
    'modifiedAt',
  );
  @override
  late final GeneratedColumn<int> modifiedAt = GeneratedColumn<int>(
    'modified_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _itemIdMeta = const VerificationMeta('itemId');
  @override
  late final GeneratedColumn<int> itemId = GeneratedColumn<int>(
    'item_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_items (id) ON DELETE SET NULL',
    ),
  );
  static const VerificationMeta _ownerFileIdMeta = const VerificationMeta(
    'ownerFileId',
  );
  @override
  late final GeneratedColumn<int> ownerFileId = GeneratedColumn<int>(
    'owner_file_id',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_files (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _matchStateMeta = const VerificationMeta(
    'matchState',
  );
  @override
  late final GeneratedColumn<String> matchState = GeneratedColumn<String>(
    'match_state',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('pending'),
  );
  static const VerificationMeta _matchLockedMeta = const VerificationMeta(
    'matchLocked',
  );
  @override
  late final GeneratedColumn<bool> matchLocked = GeneratedColumn<bool>(
    'match_locked',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("match_locked" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _parsedMeta = const VerificationMeta('parsed');
  @override
  late final GeneratedColumn<String> parsed = GeneratedColumn<String>(
    'parsed',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _versionLabelMeta = const VerificationMeta(
    'versionLabel',
  );
  @override
  late final GeneratedColumn<String> versionLabel = GeneratedColumn<String>(
    'version_label',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _languageMeta = const VerificationMeta(
    'language',
  );
  @override
  late final GeneratedColumn<String> language = GeneratedColumn<String>(
    'language',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _containerMeta = const VerificationMeta(
    'container',
  );
  @override
  late final GeneratedColumn<String> container = GeneratedColumn<String>(
    'container',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _videoCodecMeta = const VerificationMeta(
    'videoCodec',
  );
  @override
  late final GeneratedColumn<String> videoCodec = GeneratedColumn<String>(
    'video_codec',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _widthMeta = const VerificationMeta('width');
  @override
  late final GeneratedColumn<int> width = GeneratedColumn<int>(
    'width',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _heightMeta = const VerificationMeta('height');
  @override
  late final GeneratedColumn<int> height = GeneratedColumn<int>(
    'height',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _hdrFormatMeta = const VerificationMeta(
    'hdrFormat',
  );
  @override
  late final GeneratedColumn<String> hdrFormat = GeneratedColumn<String>(
    'hdr_format',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _streamsMeta = const VerificationMeta(
    'streams',
  );
  @override
  late final GeneratedColumn<String> streams = GeneratedColumn<String>(
    'streams',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _probedAtMeta = const VerificationMeta(
    'probedAt',
  );
  @override
  late final GeneratedColumn<int> probedAt = GeneratedColumn<int>(
    'probed_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _seenInScanMeta = const VerificationMeta(
    'seenInScan',
  );
  @override
  late final GeneratedColumn<int> seenInScan = GeneratedColumn<int>(
    'seen_in_scan',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<int> addedAt = GeneratedColumn<int>(
    'added_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    mountId,
    path,
    remoteId,
    size,
    modifiedAt,
    role,
    itemId,
    ownerFileId,
    matchState,
    matchLocked,
    parsed,
    versionLabel,
    language,
    durationMs,
    container,
    videoCodec,
    width,
    height,
    hdrFormat,
    streams,
    probedAt,
    seenInScan,
    addedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_files';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryFileRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('mount_id')) {
      context.handle(
        _mountIdMeta,
        mountId.isAcceptableOrUnknown(data['mount_id']!, _mountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_mountIdMeta);
    }
    if (data.containsKey('path')) {
      context.handle(
        _pathMeta,
        path.isAcceptableOrUnknown(data['path']!, _pathMeta),
      );
    } else if (isInserting) {
      context.missing(_pathMeta);
    }
    if (data.containsKey('remote_id')) {
      context.handle(
        _remoteIdMeta,
        remoteId.isAcceptableOrUnknown(data['remote_id']!, _remoteIdMeta),
      );
    }
    if (data.containsKey('size')) {
      context.handle(
        _sizeMeta,
        size.isAcceptableOrUnknown(data['size']!, _sizeMeta),
      );
    }
    if (data.containsKey('modified_at')) {
      context.handle(
        _modifiedAtMeta,
        modifiedAt.isAcceptableOrUnknown(data['modified_at']!, _modifiedAtMeta),
      );
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('item_id')) {
      context.handle(
        _itemIdMeta,
        itemId.isAcceptableOrUnknown(data['item_id']!, _itemIdMeta),
      );
    }
    if (data.containsKey('owner_file_id')) {
      context.handle(
        _ownerFileIdMeta,
        ownerFileId.isAcceptableOrUnknown(
          data['owner_file_id']!,
          _ownerFileIdMeta,
        ),
      );
    }
    if (data.containsKey('match_state')) {
      context.handle(
        _matchStateMeta,
        matchState.isAcceptableOrUnknown(data['match_state']!, _matchStateMeta),
      );
    }
    if (data.containsKey('match_locked')) {
      context.handle(
        _matchLockedMeta,
        matchLocked.isAcceptableOrUnknown(
          data['match_locked']!,
          _matchLockedMeta,
        ),
      );
    }
    if (data.containsKey('parsed')) {
      context.handle(
        _parsedMeta,
        parsed.isAcceptableOrUnknown(data['parsed']!, _parsedMeta),
      );
    }
    if (data.containsKey('version_label')) {
      context.handle(
        _versionLabelMeta,
        versionLabel.isAcceptableOrUnknown(
          data['version_label']!,
          _versionLabelMeta,
        ),
      );
    }
    if (data.containsKey('language')) {
      context.handle(
        _languageMeta,
        language.isAcceptableOrUnknown(data['language']!, _languageMeta),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('container')) {
      context.handle(
        _containerMeta,
        container.isAcceptableOrUnknown(data['container']!, _containerMeta),
      );
    }
    if (data.containsKey('video_codec')) {
      context.handle(
        _videoCodecMeta,
        videoCodec.isAcceptableOrUnknown(data['video_codec']!, _videoCodecMeta),
      );
    }
    if (data.containsKey('width')) {
      context.handle(
        _widthMeta,
        width.isAcceptableOrUnknown(data['width']!, _widthMeta),
      );
    }
    if (data.containsKey('height')) {
      context.handle(
        _heightMeta,
        height.isAcceptableOrUnknown(data['height']!, _heightMeta),
      );
    }
    if (data.containsKey('hdr_format')) {
      context.handle(
        _hdrFormatMeta,
        hdrFormat.isAcceptableOrUnknown(data['hdr_format']!, _hdrFormatMeta),
      );
    }
    if (data.containsKey('streams')) {
      context.handle(
        _streamsMeta,
        streams.isAcceptableOrUnknown(data['streams']!, _streamsMeta),
      );
    }
    if (data.containsKey('probed_at')) {
      context.handle(
        _probedAtMeta,
        probedAt.isAcceptableOrUnknown(data['probed_at']!, _probedAtMeta),
      );
    }
    if (data.containsKey('seen_in_scan')) {
      context.handle(
        _seenInScanMeta,
        seenInScan.isAcceptableOrUnknown(
          data['seen_in_scan']!,
          _seenInScanMeta,
        ),
      );
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_addedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LibraryFileRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryFileRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      mountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mount_id'],
      )!,
      path: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}path'],
      )!,
      remoteId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}remote_id'],
      ),
      size: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size'],
      ),
      modifiedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}modified_at'],
      ),
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      itemId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}item_id'],
      ),
      ownerFileId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}owner_file_id'],
      ),
      matchState: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}match_state'],
      )!,
      matchLocked: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}match_locked'],
      )!,
      parsed: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}parsed'],
      ),
      versionLabel: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}version_label'],
      ),
      language: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}language'],
      ),
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
      container: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}container'],
      ),
      videoCodec: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}video_codec'],
      ),
      width: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}width'],
      ),
      height: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}height'],
      ),
      hdrFormat: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}hdr_format'],
      ),
      streams: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}streams'],
      ),
      probedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}probed_at'],
      ),
      seenInScan: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}seen_in_scan'],
      )!,
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}added_at'],
      )!,
    );
  }

  @override
  $LibraryFilesTable createAlias(String alias) {
    return $LibraryFilesTable(attachedDatabase, alias);
  }
}

class LibraryFileRow extends DataClass implements Insertable<LibraryFileRow> {
  final int id;
  final String mountId;

  /// Mount-relative path, normalized (`/Movies/Film (2020)/film.mkv`).
  final String path;

  /// The driver's own id for the file, when it has one.
  final String? remoteId;
  final int? size;
  final int? modifiedAt;

  /// `'video'`, `'subtitle'`, `'artwork'` or `'nfo'`.
  final String role;

  /// The movie or episode a video belongs to. Null until matched.
  final int? itemId;

  /// For subtitles: the video they accompany.
  final int? ownerFileId;

  /// Videos only: `'pending'` (not looked up yet), `'matched'`,
  /// `'unmatched'` (lookup found nothing) or `'ignored'` (samples, extras).
  final String matchState;

  /// True once the user chose the match by hand; rescans keep it.
  final bool matchLocked;

  /// What the file name parser extracted, as JSON: guessed title, year,
  /// season, episode, resolution, source, release group…
  final String? parsed;

  /// What sets this version apart when an item has several: `'4K'`,
  /// `"Director's Cut"`…
  final String? versionLabel;

  /// Subtitles only: language tag taken from the file name.
  final String? language;
  final int? durationMs;
  final String? container;
  final String? videoCodec;
  final int? width;
  final int? height;
  final String? hdrFormat;

  /// Audio and embedded subtitle tracks as JSON.
  final String? streams;
  final int? probedAt;

  /// Id of the last scan run that saw this file. Rows a finished scan did
  /// not touch are gone from the mount.
  final int seenInScan;
  final int addedAt;
  const LibraryFileRow({
    required this.id,
    required this.mountId,
    required this.path,
    this.remoteId,
    this.size,
    this.modifiedAt,
    required this.role,
    this.itemId,
    this.ownerFileId,
    required this.matchState,
    required this.matchLocked,
    this.parsed,
    this.versionLabel,
    this.language,
    this.durationMs,
    this.container,
    this.videoCodec,
    this.width,
    this.height,
    this.hdrFormat,
    this.streams,
    this.probedAt,
    required this.seenInScan,
    required this.addedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['mount_id'] = Variable<String>(mountId);
    map['path'] = Variable<String>(path);
    if (!nullToAbsent || remoteId != null) {
      map['remote_id'] = Variable<String>(remoteId);
    }
    if (!nullToAbsent || size != null) {
      map['size'] = Variable<int>(size);
    }
    if (!nullToAbsent || modifiedAt != null) {
      map['modified_at'] = Variable<int>(modifiedAt);
    }
    map['role'] = Variable<String>(role);
    if (!nullToAbsent || itemId != null) {
      map['item_id'] = Variable<int>(itemId);
    }
    if (!nullToAbsent || ownerFileId != null) {
      map['owner_file_id'] = Variable<int>(ownerFileId);
    }
    map['match_state'] = Variable<String>(matchState);
    map['match_locked'] = Variable<bool>(matchLocked);
    if (!nullToAbsent || parsed != null) {
      map['parsed'] = Variable<String>(parsed);
    }
    if (!nullToAbsent || versionLabel != null) {
      map['version_label'] = Variable<String>(versionLabel);
    }
    if (!nullToAbsent || language != null) {
      map['language'] = Variable<String>(language);
    }
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    if (!nullToAbsent || container != null) {
      map['container'] = Variable<String>(container);
    }
    if (!nullToAbsent || videoCodec != null) {
      map['video_codec'] = Variable<String>(videoCodec);
    }
    if (!nullToAbsent || width != null) {
      map['width'] = Variable<int>(width);
    }
    if (!nullToAbsent || height != null) {
      map['height'] = Variable<int>(height);
    }
    if (!nullToAbsent || hdrFormat != null) {
      map['hdr_format'] = Variable<String>(hdrFormat);
    }
    if (!nullToAbsent || streams != null) {
      map['streams'] = Variable<String>(streams);
    }
    if (!nullToAbsent || probedAt != null) {
      map['probed_at'] = Variable<int>(probedAt);
    }
    map['seen_in_scan'] = Variable<int>(seenInScan);
    map['added_at'] = Variable<int>(addedAt);
    return map;
  }

  LibraryFilesCompanion toCompanion(bool nullToAbsent) {
    return LibraryFilesCompanion(
      id: Value(id),
      mountId: Value(mountId),
      path: Value(path),
      remoteId: remoteId == null && nullToAbsent
          ? const Value.absent()
          : Value(remoteId),
      size: size == null && nullToAbsent ? const Value.absent() : Value(size),
      modifiedAt: modifiedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(modifiedAt),
      role: Value(role),
      itemId: itemId == null && nullToAbsent
          ? const Value.absent()
          : Value(itemId),
      ownerFileId: ownerFileId == null && nullToAbsent
          ? const Value.absent()
          : Value(ownerFileId),
      matchState: Value(matchState),
      matchLocked: Value(matchLocked),
      parsed: parsed == null && nullToAbsent
          ? const Value.absent()
          : Value(parsed),
      versionLabel: versionLabel == null && nullToAbsent
          ? const Value.absent()
          : Value(versionLabel),
      language: language == null && nullToAbsent
          ? const Value.absent()
          : Value(language),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      container: container == null && nullToAbsent
          ? const Value.absent()
          : Value(container),
      videoCodec: videoCodec == null && nullToAbsent
          ? const Value.absent()
          : Value(videoCodec),
      width: width == null && nullToAbsent
          ? const Value.absent()
          : Value(width),
      height: height == null && nullToAbsent
          ? const Value.absent()
          : Value(height),
      hdrFormat: hdrFormat == null && nullToAbsent
          ? const Value.absent()
          : Value(hdrFormat),
      streams: streams == null && nullToAbsent
          ? const Value.absent()
          : Value(streams),
      probedAt: probedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(probedAt),
      seenInScan: Value(seenInScan),
      addedAt: Value(addedAt),
    );
  }

  factory LibraryFileRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryFileRow(
      id: serializer.fromJson<int>(json['id']),
      mountId: serializer.fromJson<String>(json['mountId']),
      path: serializer.fromJson<String>(json['path']),
      remoteId: serializer.fromJson<String?>(json['remoteId']),
      size: serializer.fromJson<int?>(json['size']),
      modifiedAt: serializer.fromJson<int?>(json['modifiedAt']),
      role: serializer.fromJson<String>(json['role']),
      itemId: serializer.fromJson<int?>(json['itemId']),
      ownerFileId: serializer.fromJson<int?>(json['ownerFileId']),
      matchState: serializer.fromJson<String>(json['matchState']),
      matchLocked: serializer.fromJson<bool>(json['matchLocked']),
      parsed: serializer.fromJson<String?>(json['parsed']),
      versionLabel: serializer.fromJson<String?>(json['versionLabel']),
      language: serializer.fromJson<String?>(json['language']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      container: serializer.fromJson<String?>(json['container']),
      videoCodec: serializer.fromJson<String?>(json['videoCodec']),
      width: serializer.fromJson<int?>(json['width']),
      height: serializer.fromJson<int?>(json['height']),
      hdrFormat: serializer.fromJson<String?>(json['hdrFormat']),
      streams: serializer.fromJson<String?>(json['streams']),
      probedAt: serializer.fromJson<int?>(json['probedAt']),
      seenInScan: serializer.fromJson<int>(json['seenInScan']),
      addedAt: serializer.fromJson<int>(json['addedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'mountId': serializer.toJson<String>(mountId),
      'path': serializer.toJson<String>(path),
      'remoteId': serializer.toJson<String?>(remoteId),
      'size': serializer.toJson<int?>(size),
      'modifiedAt': serializer.toJson<int?>(modifiedAt),
      'role': serializer.toJson<String>(role),
      'itemId': serializer.toJson<int?>(itemId),
      'ownerFileId': serializer.toJson<int?>(ownerFileId),
      'matchState': serializer.toJson<String>(matchState),
      'matchLocked': serializer.toJson<bool>(matchLocked),
      'parsed': serializer.toJson<String?>(parsed),
      'versionLabel': serializer.toJson<String?>(versionLabel),
      'language': serializer.toJson<String?>(language),
      'durationMs': serializer.toJson<int?>(durationMs),
      'container': serializer.toJson<String?>(container),
      'videoCodec': serializer.toJson<String?>(videoCodec),
      'width': serializer.toJson<int?>(width),
      'height': serializer.toJson<int?>(height),
      'hdrFormat': serializer.toJson<String?>(hdrFormat),
      'streams': serializer.toJson<String?>(streams),
      'probedAt': serializer.toJson<int?>(probedAt),
      'seenInScan': serializer.toJson<int>(seenInScan),
      'addedAt': serializer.toJson<int>(addedAt),
    };
  }

  LibraryFileRow copyWith({
    int? id,
    String? mountId,
    String? path,
    Value<String?> remoteId = const Value.absent(),
    Value<int?> size = const Value.absent(),
    Value<int?> modifiedAt = const Value.absent(),
    String? role,
    Value<int?> itemId = const Value.absent(),
    Value<int?> ownerFileId = const Value.absent(),
    String? matchState,
    bool? matchLocked,
    Value<String?> parsed = const Value.absent(),
    Value<String?> versionLabel = const Value.absent(),
    Value<String?> language = const Value.absent(),
    Value<int?> durationMs = const Value.absent(),
    Value<String?> container = const Value.absent(),
    Value<String?> videoCodec = const Value.absent(),
    Value<int?> width = const Value.absent(),
    Value<int?> height = const Value.absent(),
    Value<String?> hdrFormat = const Value.absent(),
    Value<String?> streams = const Value.absent(),
    Value<int?> probedAt = const Value.absent(),
    int? seenInScan,
    int? addedAt,
  }) => LibraryFileRow(
    id: id ?? this.id,
    mountId: mountId ?? this.mountId,
    path: path ?? this.path,
    remoteId: remoteId.present ? remoteId.value : this.remoteId,
    size: size.present ? size.value : this.size,
    modifiedAt: modifiedAt.present ? modifiedAt.value : this.modifiedAt,
    role: role ?? this.role,
    itemId: itemId.present ? itemId.value : this.itemId,
    ownerFileId: ownerFileId.present ? ownerFileId.value : this.ownerFileId,
    matchState: matchState ?? this.matchState,
    matchLocked: matchLocked ?? this.matchLocked,
    parsed: parsed.present ? parsed.value : this.parsed,
    versionLabel: versionLabel.present ? versionLabel.value : this.versionLabel,
    language: language.present ? language.value : this.language,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
    container: container.present ? container.value : this.container,
    videoCodec: videoCodec.present ? videoCodec.value : this.videoCodec,
    width: width.present ? width.value : this.width,
    height: height.present ? height.value : this.height,
    hdrFormat: hdrFormat.present ? hdrFormat.value : this.hdrFormat,
    streams: streams.present ? streams.value : this.streams,
    probedAt: probedAt.present ? probedAt.value : this.probedAt,
    seenInScan: seenInScan ?? this.seenInScan,
    addedAt: addedAt ?? this.addedAt,
  );
  LibraryFileRow copyWithCompanion(LibraryFilesCompanion data) {
    return LibraryFileRow(
      id: data.id.present ? data.id.value : this.id,
      mountId: data.mountId.present ? data.mountId.value : this.mountId,
      path: data.path.present ? data.path.value : this.path,
      remoteId: data.remoteId.present ? data.remoteId.value : this.remoteId,
      size: data.size.present ? data.size.value : this.size,
      modifiedAt: data.modifiedAt.present
          ? data.modifiedAt.value
          : this.modifiedAt,
      role: data.role.present ? data.role.value : this.role,
      itemId: data.itemId.present ? data.itemId.value : this.itemId,
      ownerFileId: data.ownerFileId.present
          ? data.ownerFileId.value
          : this.ownerFileId,
      matchState: data.matchState.present
          ? data.matchState.value
          : this.matchState,
      matchLocked: data.matchLocked.present
          ? data.matchLocked.value
          : this.matchLocked,
      parsed: data.parsed.present ? data.parsed.value : this.parsed,
      versionLabel: data.versionLabel.present
          ? data.versionLabel.value
          : this.versionLabel,
      language: data.language.present ? data.language.value : this.language,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      container: data.container.present ? data.container.value : this.container,
      videoCodec: data.videoCodec.present
          ? data.videoCodec.value
          : this.videoCodec,
      width: data.width.present ? data.width.value : this.width,
      height: data.height.present ? data.height.value : this.height,
      hdrFormat: data.hdrFormat.present ? data.hdrFormat.value : this.hdrFormat,
      streams: data.streams.present ? data.streams.value : this.streams,
      probedAt: data.probedAt.present ? data.probedAt.value : this.probedAt,
      seenInScan: data.seenInScan.present
          ? data.seenInScan.value
          : this.seenInScan,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryFileRow(')
          ..write('id: $id, ')
          ..write('mountId: $mountId, ')
          ..write('path: $path, ')
          ..write('remoteId: $remoteId, ')
          ..write('size: $size, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('role: $role, ')
          ..write('itemId: $itemId, ')
          ..write('ownerFileId: $ownerFileId, ')
          ..write('matchState: $matchState, ')
          ..write('matchLocked: $matchLocked, ')
          ..write('parsed: $parsed, ')
          ..write('versionLabel: $versionLabel, ')
          ..write('language: $language, ')
          ..write('durationMs: $durationMs, ')
          ..write('container: $container, ')
          ..write('videoCodec: $videoCodec, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('hdrFormat: $hdrFormat, ')
          ..write('streams: $streams, ')
          ..write('probedAt: $probedAt, ')
          ..write('seenInScan: $seenInScan, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hashAll([
    id,
    mountId,
    path,
    remoteId,
    size,
    modifiedAt,
    role,
    itemId,
    ownerFileId,
    matchState,
    matchLocked,
    parsed,
    versionLabel,
    language,
    durationMs,
    container,
    videoCodec,
    width,
    height,
    hdrFormat,
    streams,
    probedAt,
    seenInScan,
    addedAt,
  ]);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryFileRow &&
          other.id == this.id &&
          other.mountId == this.mountId &&
          other.path == this.path &&
          other.remoteId == this.remoteId &&
          other.size == this.size &&
          other.modifiedAt == this.modifiedAt &&
          other.role == this.role &&
          other.itemId == this.itemId &&
          other.ownerFileId == this.ownerFileId &&
          other.matchState == this.matchState &&
          other.matchLocked == this.matchLocked &&
          other.parsed == this.parsed &&
          other.versionLabel == this.versionLabel &&
          other.language == this.language &&
          other.durationMs == this.durationMs &&
          other.container == this.container &&
          other.videoCodec == this.videoCodec &&
          other.width == this.width &&
          other.height == this.height &&
          other.hdrFormat == this.hdrFormat &&
          other.streams == this.streams &&
          other.probedAt == this.probedAt &&
          other.seenInScan == this.seenInScan &&
          other.addedAt == this.addedAt);
}

class LibraryFilesCompanion extends UpdateCompanion<LibraryFileRow> {
  final Value<int> id;
  final Value<String> mountId;
  final Value<String> path;
  final Value<String?> remoteId;
  final Value<int?> size;
  final Value<int?> modifiedAt;
  final Value<String> role;
  final Value<int?> itemId;
  final Value<int?> ownerFileId;
  final Value<String> matchState;
  final Value<bool> matchLocked;
  final Value<String?> parsed;
  final Value<String?> versionLabel;
  final Value<String?> language;
  final Value<int?> durationMs;
  final Value<String?> container;
  final Value<String?> videoCodec;
  final Value<int?> width;
  final Value<int?> height;
  final Value<String?> hdrFormat;
  final Value<String?> streams;
  final Value<int?> probedAt;
  final Value<int> seenInScan;
  final Value<int> addedAt;
  const LibraryFilesCompanion({
    this.id = const Value.absent(),
    this.mountId = const Value.absent(),
    this.path = const Value.absent(),
    this.remoteId = const Value.absent(),
    this.size = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    this.role = const Value.absent(),
    this.itemId = const Value.absent(),
    this.ownerFileId = const Value.absent(),
    this.matchState = const Value.absent(),
    this.matchLocked = const Value.absent(),
    this.parsed = const Value.absent(),
    this.versionLabel = const Value.absent(),
    this.language = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.container = const Value.absent(),
    this.videoCodec = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.hdrFormat = const Value.absent(),
    this.streams = const Value.absent(),
    this.probedAt = const Value.absent(),
    this.seenInScan = const Value.absent(),
    this.addedAt = const Value.absent(),
  });
  LibraryFilesCompanion.insert({
    this.id = const Value.absent(),
    required String mountId,
    required String path,
    this.remoteId = const Value.absent(),
    this.size = const Value.absent(),
    this.modifiedAt = const Value.absent(),
    required String role,
    this.itemId = const Value.absent(),
    this.ownerFileId = const Value.absent(),
    this.matchState = const Value.absent(),
    this.matchLocked = const Value.absent(),
    this.parsed = const Value.absent(),
    this.versionLabel = const Value.absent(),
    this.language = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.container = const Value.absent(),
    this.videoCodec = const Value.absent(),
    this.width = const Value.absent(),
    this.height = const Value.absent(),
    this.hdrFormat = const Value.absent(),
    this.streams = const Value.absent(),
    this.probedAt = const Value.absent(),
    this.seenInScan = const Value.absent(),
    required int addedAt,
  }) : mountId = Value(mountId),
       path = Value(path),
       role = Value(role),
       addedAt = Value(addedAt);
  static Insertable<LibraryFileRow> custom({
    Expression<int>? id,
    Expression<String>? mountId,
    Expression<String>? path,
    Expression<String>? remoteId,
    Expression<int>? size,
    Expression<int>? modifiedAt,
    Expression<String>? role,
    Expression<int>? itemId,
    Expression<int>? ownerFileId,
    Expression<String>? matchState,
    Expression<bool>? matchLocked,
    Expression<String>? parsed,
    Expression<String>? versionLabel,
    Expression<String>? language,
    Expression<int>? durationMs,
    Expression<String>? container,
    Expression<String>? videoCodec,
    Expression<int>? width,
    Expression<int>? height,
    Expression<String>? hdrFormat,
    Expression<String>? streams,
    Expression<int>? probedAt,
    Expression<int>? seenInScan,
    Expression<int>? addedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (mountId != null) 'mount_id': mountId,
      if (path != null) 'path': path,
      if (remoteId != null) 'remote_id': remoteId,
      if (size != null) 'size': size,
      if (modifiedAt != null) 'modified_at': modifiedAt,
      if (role != null) 'role': role,
      if (itemId != null) 'item_id': itemId,
      if (ownerFileId != null) 'owner_file_id': ownerFileId,
      if (matchState != null) 'match_state': matchState,
      if (matchLocked != null) 'match_locked': matchLocked,
      if (parsed != null) 'parsed': parsed,
      if (versionLabel != null) 'version_label': versionLabel,
      if (language != null) 'language': language,
      if (durationMs != null) 'duration_ms': durationMs,
      if (container != null) 'container': container,
      if (videoCodec != null) 'video_codec': videoCodec,
      if (width != null) 'width': width,
      if (height != null) 'height': height,
      if (hdrFormat != null) 'hdr_format': hdrFormat,
      if (streams != null) 'streams': streams,
      if (probedAt != null) 'probed_at': probedAt,
      if (seenInScan != null) 'seen_in_scan': seenInScan,
      if (addedAt != null) 'added_at': addedAt,
    });
  }

  LibraryFilesCompanion copyWith({
    Value<int>? id,
    Value<String>? mountId,
    Value<String>? path,
    Value<String?>? remoteId,
    Value<int?>? size,
    Value<int?>? modifiedAt,
    Value<String>? role,
    Value<int?>? itemId,
    Value<int?>? ownerFileId,
    Value<String>? matchState,
    Value<bool>? matchLocked,
    Value<String?>? parsed,
    Value<String?>? versionLabel,
    Value<String?>? language,
    Value<int?>? durationMs,
    Value<String?>? container,
    Value<String?>? videoCodec,
    Value<int?>? width,
    Value<int?>? height,
    Value<String?>? hdrFormat,
    Value<String?>? streams,
    Value<int?>? probedAt,
    Value<int>? seenInScan,
    Value<int>? addedAt,
  }) {
    return LibraryFilesCompanion(
      id: id ?? this.id,
      mountId: mountId ?? this.mountId,
      path: path ?? this.path,
      remoteId: remoteId ?? this.remoteId,
      size: size ?? this.size,
      modifiedAt: modifiedAt ?? this.modifiedAt,
      role: role ?? this.role,
      itemId: itemId ?? this.itemId,
      ownerFileId: ownerFileId ?? this.ownerFileId,
      matchState: matchState ?? this.matchState,
      matchLocked: matchLocked ?? this.matchLocked,
      parsed: parsed ?? this.parsed,
      versionLabel: versionLabel ?? this.versionLabel,
      language: language ?? this.language,
      durationMs: durationMs ?? this.durationMs,
      container: container ?? this.container,
      videoCodec: videoCodec ?? this.videoCodec,
      width: width ?? this.width,
      height: height ?? this.height,
      hdrFormat: hdrFormat ?? this.hdrFormat,
      streams: streams ?? this.streams,
      probedAt: probedAt ?? this.probedAt,
      seenInScan: seenInScan ?? this.seenInScan,
      addedAt: addedAt ?? this.addedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (mountId.present) {
      map['mount_id'] = Variable<String>(mountId.value);
    }
    if (path.present) {
      map['path'] = Variable<String>(path.value);
    }
    if (remoteId.present) {
      map['remote_id'] = Variable<String>(remoteId.value);
    }
    if (size.present) {
      map['size'] = Variable<int>(size.value);
    }
    if (modifiedAt.present) {
      map['modified_at'] = Variable<int>(modifiedAt.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (itemId.present) {
      map['item_id'] = Variable<int>(itemId.value);
    }
    if (ownerFileId.present) {
      map['owner_file_id'] = Variable<int>(ownerFileId.value);
    }
    if (matchState.present) {
      map['match_state'] = Variable<String>(matchState.value);
    }
    if (matchLocked.present) {
      map['match_locked'] = Variable<bool>(matchLocked.value);
    }
    if (parsed.present) {
      map['parsed'] = Variable<String>(parsed.value);
    }
    if (versionLabel.present) {
      map['version_label'] = Variable<String>(versionLabel.value);
    }
    if (language.present) {
      map['language'] = Variable<String>(language.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (container.present) {
      map['container'] = Variable<String>(container.value);
    }
    if (videoCodec.present) {
      map['video_codec'] = Variable<String>(videoCodec.value);
    }
    if (width.present) {
      map['width'] = Variable<int>(width.value);
    }
    if (height.present) {
      map['height'] = Variable<int>(height.value);
    }
    if (hdrFormat.present) {
      map['hdr_format'] = Variable<String>(hdrFormat.value);
    }
    if (streams.present) {
      map['streams'] = Variable<String>(streams.value);
    }
    if (probedAt.present) {
      map['probed_at'] = Variable<int>(probedAt.value);
    }
    if (seenInScan.present) {
      map['seen_in_scan'] = Variable<int>(seenInScan.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<int>(addedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryFilesCompanion(')
          ..write('id: $id, ')
          ..write('mountId: $mountId, ')
          ..write('path: $path, ')
          ..write('remoteId: $remoteId, ')
          ..write('size: $size, ')
          ..write('modifiedAt: $modifiedAt, ')
          ..write('role: $role, ')
          ..write('itemId: $itemId, ')
          ..write('ownerFileId: $ownerFileId, ')
          ..write('matchState: $matchState, ')
          ..write('matchLocked: $matchLocked, ')
          ..write('parsed: $parsed, ')
          ..write('versionLabel: $versionLabel, ')
          ..write('language: $language, ')
          ..write('durationMs: $durationMs, ')
          ..write('container: $container, ')
          ..write('videoCodec: $videoCodec, ')
          ..write('width: $width, ')
          ..write('height: $height, ')
          ..write('hdrFormat: $hdrFormat, ')
          ..write('streams: $streams, ')
          ..write('probedAt: $probedAt, ')
          ..write('seenInScan: $seenInScan, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }
}

class $LibraryUserStatesTable extends LibraryUserStates
    with TableInfo<$LibraryUserStatesTable, LibraryUserStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryUserStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _itemIdMeta = const VerificationMeta('itemId');
  @override
  late final GeneratedColumn<int> itemId = GeneratedColumn<int>(
    'item_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_items (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _positionMsMeta = const VerificationMeta(
    'positionMs',
  );
  @override
  late final GeneratedColumn<int> positionMs = GeneratedColumn<int>(
    'position_ms',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _durationMsMeta = const VerificationMeta(
    'durationMs',
  );
  @override
  late final GeneratedColumn<int> durationMs = GeneratedColumn<int>(
    'duration_ms',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _watchedMeta = const VerificationMeta(
    'watched',
  );
  @override
  late final GeneratedColumn<bool> watched = GeneratedColumn<bool>(
    'watched',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("watched" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _playCountMeta = const VerificationMeta(
    'playCount',
  );
  @override
  late final GeneratedColumn<int> playCount = GeneratedColumn<int>(
    'play_count',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _lastPlayedAtMeta = const VerificationMeta(
    'lastPlayedAt',
  );
  @override
  late final GeneratedColumn<int> lastPlayedAt = GeneratedColumn<int>(
    'last_played_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _favoriteMeta = const VerificationMeta(
    'favorite',
  );
  @override
  late final GeneratedColumn<bool> favorite = GeneratedColumn<bool>(
    'favorite',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("favorite" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _hiddenFromContinueMeta =
      const VerificationMeta('hiddenFromContinue');
  @override
  late final GeneratedColumn<bool> hiddenFromContinue = GeneratedColumn<bool>(
    'hidden_from_continue',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("hidden_from_continue" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    itemId,
    positionMs,
    durationMs,
    watched,
    playCount,
    lastPlayedAt,
    favorite,
    hiddenFromContinue,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_user_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryUserStateRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('item_id')) {
      context.handle(
        _itemIdMeta,
        itemId.isAcceptableOrUnknown(data['item_id']!, _itemIdMeta),
      );
    }
    if (data.containsKey('position_ms')) {
      context.handle(
        _positionMsMeta,
        positionMs.isAcceptableOrUnknown(data['position_ms']!, _positionMsMeta),
      );
    }
    if (data.containsKey('duration_ms')) {
      context.handle(
        _durationMsMeta,
        durationMs.isAcceptableOrUnknown(data['duration_ms']!, _durationMsMeta),
      );
    }
    if (data.containsKey('watched')) {
      context.handle(
        _watchedMeta,
        watched.isAcceptableOrUnknown(data['watched']!, _watchedMeta),
      );
    }
    if (data.containsKey('play_count')) {
      context.handle(
        _playCountMeta,
        playCount.isAcceptableOrUnknown(data['play_count']!, _playCountMeta),
      );
    }
    if (data.containsKey('last_played_at')) {
      context.handle(
        _lastPlayedAtMeta,
        lastPlayedAt.isAcceptableOrUnknown(
          data['last_played_at']!,
          _lastPlayedAtMeta,
        ),
      );
    }
    if (data.containsKey('favorite')) {
      context.handle(
        _favoriteMeta,
        favorite.isAcceptableOrUnknown(data['favorite']!, _favoriteMeta),
      );
    }
    if (data.containsKey('hidden_from_continue')) {
      context.handle(
        _hiddenFromContinueMeta,
        hiddenFromContinue.isAcceptableOrUnknown(
          data['hidden_from_continue']!,
          _hiddenFromContinueMeta,
        ),
      );
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {itemId};
  @override
  LibraryUserStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryUserStateRow(
      itemId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}item_id'],
      )!,
      positionMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position_ms'],
      )!,
      durationMs: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_ms'],
      ),
      watched: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}watched'],
      )!,
      playCount: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}play_count'],
      )!,
      lastPlayedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}last_played_at'],
      ),
      favorite: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}favorite'],
      )!,
      hiddenFromContinue: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}hidden_from_continue'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LibraryUserStatesTable createAlias(String alias) {
    return $LibraryUserStatesTable(attachedDatabase, alias);
  }
}

class LibraryUserStateRow extends DataClass
    implements Insertable<LibraryUserStateRow> {
  final int itemId;
  final int positionMs;
  final int? durationMs;
  final bool watched;
  final int playCount;
  final int? lastPlayedAt;
  final bool favorite;

  /// Hidden from Continue Watching without touching progress.
  final bool hiddenFromContinue;
  final int updatedAt;
  const LibraryUserStateRow({
    required this.itemId,
    required this.positionMs,
    this.durationMs,
    required this.watched,
    required this.playCount,
    this.lastPlayedAt,
    required this.favorite,
    required this.hiddenFromContinue,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['item_id'] = Variable<int>(itemId);
    map['position_ms'] = Variable<int>(positionMs);
    if (!nullToAbsent || durationMs != null) {
      map['duration_ms'] = Variable<int>(durationMs);
    }
    map['watched'] = Variable<bool>(watched);
    map['play_count'] = Variable<int>(playCount);
    if (!nullToAbsent || lastPlayedAt != null) {
      map['last_played_at'] = Variable<int>(lastPlayedAt);
    }
    map['favorite'] = Variable<bool>(favorite);
    map['hidden_from_continue'] = Variable<bool>(hiddenFromContinue);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  LibraryUserStatesCompanion toCompanion(bool nullToAbsent) {
    return LibraryUserStatesCompanion(
      itemId: Value(itemId),
      positionMs: Value(positionMs),
      durationMs: durationMs == null && nullToAbsent
          ? const Value.absent()
          : Value(durationMs),
      watched: Value(watched),
      playCount: Value(playCount),
      lastPlayedAt: lastPlayedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastPlayedAt),
      favorite: Value(favorite),
      hiddenFromContinue: Value(hiddenFromContinue),
      updatedAt: Value(updatedAt),
    );
  }

  factory LibraryUserStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryUserStateRow(
      itemId: serializer.fromJson<int>(json['itemId']),
      positionMs: serializer.fromJson<int>(json['positionMs']),
      durationMs: serializer.fromJson<int?>(json['durationMs']),
      watched: serializer.fromJson<bool>(json['watched']),
      playCount: serializer.fromJson<int>(json['playCount']),
      lastPlayedAt: serializer.fromJson<int?>(json['lastPlayedAt']),
      favorite: serializer.fromJson<bool>(json['favorite']),
      hiddenFromContinue: serializer.fromJson<bool>(json['hiddenFromContinue']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'itemId': serializer.toJson<int>(itemId),
      'positionMs': serializer.toJson<int>(positionMs),
      'durationMs': serializer.toJson<int?>(durationMs),
      'watched': serializer.toJson<bool>(watched),
      'playCount': serializer.toJson<int>(playCount),
      'lastPlayedAt': serializer.toJson<int?>(lastPlayedAt),
      'favorite': serializer.toJson<bool>(favorite),
      'hiddenFromContinue': serializer.toJson<bool>(hiddenFromContinue),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  LibraryUserStateRow copyWith({
    int? itemId,
    int? positionMs,
    Value<int?> durationMs = const Value.absent(),
    bool? watched,
    int? playCount,
    Value<int?> lastPlayedAt = const Value.absent(),
    bool? favorite,
    bool? hiddenFromContinue,
    int? updatedAt,
  }) => LibraryUserStateRow(
    itemId: itemId ?? this.itemId,
    positionMs: positionMs ?? this.positionMs,
    durationMs: durationMs.present ? durationMs.value : this.durationMs,
    watched: watched ?? this.watched,
    playCount: playCount ?? this.playCount,
    lastPlayedAt: lastPlayedAt.present ? lastPlayedAt.value : this.lastPlayedAt,
    favorite: favorite ?? this.favorite,
    hiddenFromContinue: hiddenFromContinue ?? this.hiddenFromContinue,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  LibraryUserStateRow copyWithCompanion(LibraryUserStatesCompanion data) {
    return LibraryUserStateRow(
      itemId: data.itemId.present ? data.itemId.value : this.itemId,
      positionMs: data.positionMs.present
          ? data.positionMs.value
          : this.positionMs,
      durationMs: data.durationMs.present
          ? data.durationMs.value
          : this.durationMs,
      watched: data.watched.present ? data.watched.value : this.watched,
      playCount: data.playCount.present ? data.playCount.value : this.playCount,
      lastPlayedAt: data.lastPlayedAt.present
          ? data.lastPlayedAt.value
          : this.lastPlayedAt,
      favorite: data.favorite.present ? data.favorite.value : this.favorite,
      hiddenFromContinue: data.hiddenFromContinue.present
          ? data.hiddenFromContinue.value
          : this.hiddenFromContinue,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryUserStateRow(')
          ..write('itemId: $itemId, ')
          ..write('positionMs: $positionMs, ')
          ..write('durationMs: $durationMs, ')
          ..write('watched: $watched, ')
          ..write('playCount: $playCount, ')
          ..write('lastPlayedAt: $lastPlayedAt, ')
          ..write('favorite: $favorite, ')
          ..write('hiddenFromContinue: $hiddenFromContinue, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    itemId,
    positionMs,
    durationMs,
    watched,
    playCount,
    lastPlayedAt,
    favorite,
    hiddenFromContinue,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryUserStateRow &&
          other.itemId == this.itemId &&
          other.positionMs == this.positionMs &&
          other.durationMs == this.durationMs &&
          other.watched == this.watched &&
          other.playCount == this.playCount &&
          other.lastPlayedAt == this.lastPlayedAt &&
          other.favorite == this.favorite &&
          other.hiddenFromContinue == this.hiddenFromContinue &&
          other.updatedAt == this.updatedAt);
}

class LibraryUserStatesCompanion extends UpdateCompanion<LibraryUserStateRow> {
  final Value<int> itemId;
  final Value<int> positionMs;
  final Value<int?> durationMs;
  final Value<bool> watched;
  final Value<int> playCount;
  final Value<int?> lastPlayedAt;
  final Value<bool> favorite;
  final Value<bool> hiddenFromContinue;
  final Value<int> updatedAt;
  const LibraryUserStatesCompanion({
    this.itemId = const Value.absent(),
    this.positionMs = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.watched = const Value.absent(),
    this.playCount = const Value.absent(),
    this.lastPlayedAt = const Value.absent(),
    this.favorite = const Value.absent(),
    this.hiddenFromContinue = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  LibraryUserStatesCompanion.insert({
    this.itemId = const Value.absent(),
    this.positionMs = const Value.absent(),
    this.durationMs = const Value.absent(),
    this.watched = const Value.absent(),
    this.playCount = const Value.absent(),
    this.lastPlayedAt = const Value.absent(),
    this.favorite = const Value.absent(),
    this.hiddenFromContinue = const Value.absent(),
    required int updatedAt,
  }) : updatedAt = Value(updatedAt);
  static Insertable<LibraryUserStateRow> custom({
    Expression<int>? itemId,
    Expression<int>? positionMs,
    Expression<int>? durationMs,
    Expression<bool>? watched,
    Expression<int>? playCount,
    Expression<int>? lastPlayedAt,
    Expression<bool>? favorite,
    Expression<bool>? hiddenFromContinue,
    Expression<int>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (itemId != null) 'item_id': itemId,
      if (positionMs != null) 'position_ms': positionMs,
      if (durationMs != null) 'duration_ms': durationMs,
      if (watched != null) 'watched': watched,
      if (playCount != null) 'play_count': playCount,
      if (lastPlayedAt != null) 'last_played_at': lastPlayedAt,
      if (favorite != null) 'favorite': favorite,
      if (hiddenFromContinue != null)
        'hidden_from_continue': hiddenFromContinue,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  LibraryUserStatesCompanion copyWith({
    Value<int>? itemId,
    Value<int>? positionMs,
    Value<int?>? durationMs,
    Value<bool>? watched,
    Value<int>? playCount,
    Value<int?>? lastPlayedAt,
    Value<bool>? favorite,
    Value<bool>? hiddenFromContinue,
    Value<int>? updatedAt,
  }) {
    return LibraryUserStatesCompanion(
      itemId: itemId ?? this.itemId,
      positionMs: positionMs ?? this.positionMs,
      durationMs: durationMs ?? this.durationMs,
      watched: watched ?? this.watched,
      playCount: playCount ?? this.playCount,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      favorite: favorite ?? this.favorite,
      hiddenFromContinue: hiddenFromContinue ?? this.hiddenFromContinue,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (itemId.present) {
      map['item_id'] = Variable<int>(itemId.value);
    }
    if (positionMs.present) {
      map['position_ms'] = Variable<int>(positionMs.value);
    }
    if (durationMs.present) {
      map['duration_ms'] = Variable<int>(durationMs.value);
    }
    if (watched.present) {
      map['watched'] = Variable<bool>(watched.value);
    }
    if (playCount.present) {
      map['play_count'] = Variable<int>(playCount.value);
    }
    if (lastPlayedAt.present) {
      map['last_played_at'] = Variable<int>(lastPlayedAt.value);
    }
    if (favorite.present) {
      map['favorite'] = Variable<bool>(favorite.value);
    }
    if (hiddenFromContinue.present) {
      map['hidden_from_continue'] = Variable<bool>(hiddenFromContinue.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryUserStatesCompanion(')
          ..write('itemId: $itemId, ')
          ..write('positionMs: $positionMs, ')
          ..write('durationMs: $durationMs, ')
          ..write('watched: $watched, ')
          ..write('playCount: $playCount, ')
          ..write('lastPlayedAt: $lastPlayedAt, ')
          ..write('favorite: $favorite, ')
          ..write('hiddenFromContinue: $hiddenFromContinue, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $LibraryGenresTable extends LibraryGenres
    with TableInfo<$LibraryGenresTable, LibraryGenreRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryGenresTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('UNIQUE'),
  );
  @override
  List<GeneratedColumn> get $columns => [id, name];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_genres';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryGenreRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LibraryGenreRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryGenreRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
    );
  }

  @override
  $LibraryGenresTable createAlias(String alias) {
    return $LibraryGenresTable(attachedDatabase, alias);
  }
}

class LibraryGenreRow extends DataClass implements Insertable<LibraryGenreRow> {
  final int id;
  final String name;
  const LibraryGenreRow({required this.id, required this.name});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    return map;
  }

  LibraryGenresCompanion toCompanion(bool nullToAbsent) {
    return LibraryGenresCompanion(id: Value(id), name: Value(name));
  }

  factory LibraryGenreRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryGenreRow(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
    };
  }

  LibraryGenreRow copyWith({int? id, String? name}) =>
      LibraryGenreRow(id: id ?? this.id, name: name ?? this.name);
  LibraryGenreRow copyWithCompanion(LibraryGenresCompanion data) {
    return LibraryGenreRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryGenreRow(')
          ..write('id: $id, ')
          ..write('name: $name')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryGenreRow &&
          other.id == this.id &&
          other.name == this.name);
}

class LibraryGenresCompanion extends UpdateCompanion<LibraryGenreRow> {
  final Value<int> id;
  final Value<String> name;
  const LibraryGenresCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
  });
  LibraryGenresCompanion.insert({
    this.id = const Value.absent(),
    required String name,
  }) : name = Value(name);
  static Insertable<LibraryGenreRow> custom({
    Expression<int>? id,
    Expression<String>? name,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
    });
  }

  LibraryGenresCompanion copyWith({Value<int>? id, Value<String>? name}) {
    return LibraryGenresCompanion(id: id ?? this.id, name: name ?? this.name);
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryGenresCompanion(')
          ..write('id: $id, ')
          ..write('name: $name')
          ..write(')'))
        .toString();
  }
}

class $LibraryItemGenresTable extends LibraryItemGenres
    with TableInfo<$LibraryItemGenresTable, LibraryItemGenreRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryItemGenresTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _itemIdMeta = const VerificationMeta('itemId');
  @override
  late final GeneratedColumn<int> itemId = GeneratedColumn<int>(
    'item_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_items (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _genreIdMeta = const VerificationMeta(
    'genreId',
  );
  @override
  late final GeneratedColumn<int> genreId = GeneratedColumn<int>(
    'genre_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_genres (id) ON DELETE CASCADE',
    ),
  );
  @override
  List<GeneratedColumn> get $columns => [itemId, genreId];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_item_genres';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryItemGenreRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('item_id')) {
      context.handle(
        _itemIdMeta,
        itemId.isAcceptableOrUnknown(data['item_id']!, _itemIdMeta),
      );
    } else if (isInserting) {
      context.missing(_itemIdMeta);
    }
    if (data.containsKey('genre_id')) {
      context.handle(
        _genreIdMeta,
        genreId.isAcceptableOrUnknown(data['genre_id']!, _genreIdMeta),
      );
    } else if (isInserting) {
      context.missing(_genreIdMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {itemId, genreId};
  @override
  LibraryItemGenreRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryItemGenreRow(
      itemId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}item_id'],
      )!,
      genreId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}genre_id'],
      )!,
    );
  }

  @override
  $LibraryItemGenresTable createAlias(String alias) {
    return $LibraryItemGenresTable(attachedDatabase, alias);
  }
}

class LibraryItemGenreRow extends DataClass
    implements Insertable<LibraryItemGenreRow> {
  final int itemId;
  final int genreId;
  const LibraryItemGenreRow({required this.itemId, required this.genreId});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['item_id'] = Variable<int>(itemId);
    map['genre_id'] = Variable<int>(genreId);
    return map;
  }

  LibraryItemGenresCompanion toCompanion(bool nullToAbsent) {
    return LibraryItemGenresCompanion(
      itemId: Value(itemId),
      genreId: Value(genreId),
    );
  }

  factory LibraryItemGenreRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryItemGenreRow(
      itemId: serializer.fromJson<int>(json['itemId']),
      genreId: serializer.fromJson<int>(json['genreId']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'itemId': serializer.toJson<int>(itemId),
      'genreId': serializer.toJson<int>(genreId),
    };
  }

  LibraryItemGenreRow copyWith({int? itemId, int? genreId}) =>
      LibraryItemGenreRow(
        itemId: itemId ?? this.itemId,
        genreId: genreId ?? this.genreId,
      );
  LibraryItemGenreRow copyWithCompanion(LibraryItemGenresCompanion data) {
    return LibraryItemGenreRow(
      itemId: data.itemId.present ? data.itemId.value : this.itemId,
      genreId: data.genreId.present ? data.genreId.value : this.genreId,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryItemGenreRow(')
          ..write('itemId: $itemId, ')
          ..write('genreId: $genreId')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(itemId, genreId);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryItemGenreRow &&
          other.itemId == this.itemId &&
          other.genreId == this.genreId);
}

class LibraryItemGenresCompanion extends UpdateCompanion<LibraryItemGenreRow> {
  final Value<int> itemId;
  final Value<int> genreId;
  final Value<int> rowid;
  const LibraryItemGenresCompanion({
    this.itemId = const Value.absent(),
    this.genreId = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibraryItemGenresCompanion.insert({
    required int itemId,
    required int genreId,
    this.rowid = const Value.absent(),
  }) : itemId = Value(itemId),
       genreId = Value(genreId);
  static Insertable<LibraryItemGenreRow> custom({
    Expression<int>? itemId,
    Expression<int>? genreId,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (itemId != null) 'item_id': itemId,
      if (genreId != null) 'genre_id': genreId,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibraryItemGenresCompanion copyWith({
    Value<int>? itemId,
    Value<int>? genreId,
    Value<int>? rowid,
  }) {
    return LibraryItemGenresCompanion(
      itemId: itemId ?? this.itemId,
      genreId: genreId ?? this.genreId,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (itemId.present) {
      map['item_id'] = Variable<int>(itemId.value);
    }
    if (genreId.present) {
      map['genre_id'] = Variable<int>(genreId.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryItemGenresCompanion(')
          ..write('itemId: $itemId, ')
          ..write('genreId: $genreId, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LibraryPeopleTable extends LibraryPeople
    with TableInfo<$LibraryPeopleTable, LibraryPersonRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryPeopleTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _tmdbIdMeta = const VerificationMeta('tmdbId');
  @override
  late final GeneratedColumn<String> tmdbId = GeneratedColumn<String>(
    'tmdb_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _photoSourceMeta = const VerificationMeta(
    'photoSource',
  );
  @override
  late final GeneratedColumn<String> photoSource = GeneratedColumn<String>(
    'photo_source',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [id, name, tmdbId, photoSource];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_people';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryPersonRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('tmdb_id')) {
      context.handle(
        _tmdbIdMeta,
        tmdbId.isAcceptableOrUnknown(data['tmdb_id']!, _tmdbIdMeta),
      );
    }
    if (data.containsKey('photo_source')) {
      context.handle(
        _photoSourceMeta,
        photoSource.isAcceptableOrUnknown(
          data['photo_source']!,
          _photoSourceMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LibraryPersonRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryPersonRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      tmdbId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tmdb_id'],
      ),
      photoSource: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}photo_source'],
      ),
    );
  }

  @override
  $LibraryPeopleTable createAlias(String alias) {
    return $LibraryPeopleTable(attachedDatabase, alias);
  }
}

class LibraryPersonRow extends DataClass
    implements Insertable<LibraryPersonRow> {
  final int id;
  final String name;
  final String? tmdbId;
  final String? photoSource;
  const LibraryPersonRow({
    required this.id,
    required this.name,
    this.tmdbId,
    this.photoSource,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || tmdbId != null) {
      map['tmdb_id'] = Variable<String>(tmdbId);
    }
    if (!nullToAbsent || photoSource != null) {
      map['photo_source'] = Variable<String>(photoSource);
    }
    return map;
  }

  LibraryPeopleCompanion toCompanion(bool nullToAbsent) {
    return LibraryPeopleCompanion(
      id: Value(id),
      name: Value(name),
      tmdbId: tmdbId == null && nullToAbsent
          ? const Value.absent()
          : Value(tmdbId),
      photoSource: photoSource == null && nullToAbsent
          ? const Value.absent()
          : Value(photoSource),
    );
  }

  factory LibraryPersonRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryPersonRow(
      id: serializer.fromJson<int>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      tmdbId: serializer.fromJson<String?>(json['tmdbId']),
      photoSource: serializer.fromJson<String?>(json['photoSource']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'name': serializer.toJson<String>(name),
      'tmdbId': serializer.toJson<String?>(tmdbId),
      'photoSource': serializer.toJson<String?>(photoSource),
    };
  }

  LibraryPersonRow copyWith({
    int? id,
    String? name,
    Value<String?> tmdbId = const Value.absent(),
    Value<String?> photoSource = const Value.absent(),
  }) => LibraryPersonRow(
    id: id ?? this.id,
    name: name ?? this.name,
    tmdbId: tmdbId.present ? tmdbId.value : this.tmdbId,
    photoSource: photoSource.present ? photoSource.value : this.photoSource,
  );
  LibraryPersonRow copyWithCompanion(LibraryPeopleCompanion data) {
    return LibraryPersonRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      tmdbId: data.tmdbId.present ? data.tmdbId.value : this.tmdbId,
      photoSource: data.photoSource.present
          ? data.photoSource.value
          : this.photoSource,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryPersonRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('photoSource: $photoSource')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, name, tmdbId, photoSource);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryPersonRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.tmdbId == this.tmdbId &&
          other.photoSource == this.photoSource);
}

class LibraryPeopleCompanion extends UpdateCompanion<LibraryPersonRow> {
  final Value<int> id;
  final Value<String> name;
  final Value<String?> tmdbId;
  final Value<String?> photoSource;
  const LibraryPeopleCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.tmdbId = const Value.absent(),
    this.photoSource = const Value.absent(),
  });
  LibraryPeopleCompanion.insert({
    this.id = const Value.absent(),
    required String name,
    this.tmdbId = const Value.absent(),
    this.photoSource = const Value.absent(),
  }) : name = Value(name);
  static Insertable<LibraryPersonRow> custom({
    Expression<int>? id,
    Expression<String>? name,
    Expression<String>? tmdbId,
    Expression<String>? photoSource,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (tmdbId != null) 'tmdb_id': tmdbId,
      if (photoSource != null) 'photo_source': photoSource,
    });
  }

  LibraryPeopleCompanion copyWith({
    Value<int>? id,
    Value<String>? name,
    Value<String?>? tmdbId,
    Value<String?>? photoSource,
  }) {
    return LibraryPeopleCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      tmdbId: tmdbId ?? this.tmdbId,
      photoSource: photoSource ?? this.photoSource,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (tmdbId.present) {
      map['tmdb_id'] = Variable<String>(tmdbId.value);
    }
    if (photoSource.present) {
      map['photo_source'] = Variable<String>(photoSource.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryPeopleCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('photoSource: $photoSource')
          ..write(')'))
        .toString();
  }
}

class $LibraryCreditsTable extends LibraryCredits
    with TableInfo<$LibraryCreditsTable, LibraryCreditRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryCreditsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _itemIdMeta = const VerificationMeta('itemId');
  @override
  late final GeneratedColumn<int> itemId = GeneratedColumn<int>(
    'item_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_items (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _personIdMeta = const VerificationMeta(
    'personId',
  );
  @override
  late final GeneratedColumn<int> personId = GeneratedColumn<int>(
    'person_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_people (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _jobMeta = const VerificationMeta('job');
  @override
  late final GeneratedColumn<String> job = GeneratedColumn<String>(
    'job',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _characterMeta = const VerificationMeta(
    'character',
  );
  @override
  late final GeneratedColumn<String> character = GeneratedColumn<String>(
    'character',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [
    itemId,
    personId,
    job,
    character,
    sortOrder,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_credits';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryCreditRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('item_id')) {
      context.handle(
        _itemIdMeta,
        itemId.isAcceptableOrUnknown(data['item_id']!, _itemIdMeta),
      );
    } else if (isInserting) {
      context.missing(_itemIdMeta);
    }
    if (data.containsKey('person_id')) {
      context.handle(
        _personIdMeta,
        personId.isAcceptableOrUnknown(data['person_id']!, _personIdMeta),
      );
    } else if (isInserting) {
      context.missing(_personIdMeta);
    }
    if (data.containsKey('job')) {
      context.handle(
        _jobMeta,
        job.isAcceptableOrUnknown(data['job']!, _jobMeta),
      );
    } else if (isInserting) {
      context.missing(_jobMeta);
    }
    if (data.containsKey('character')) {
      context.handle(
        _characterMeta,
        character.isAcceptableOrUnknown(data['character']!, _characterMeta),
      );
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {itemId, personId, job};
  @override
  LibraryCreditRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryCreditRow(
      itemId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}item_id'],
      )!,
      personId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}person_id'],
      )!,
      job: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}job'],
      )!,
      character: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}character'],
      ),
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $LibraryCreditsTable createAlias(String alias) {
    return $LibraryCreditsTable(attachedDatabase, alias);
  }
}

class LibraryCreditRow extends DataClass
    implements Insertable<LibraryCreditRow> {
  final int itemId;
  final int personId;

  /// `'actor'`, `'director'` or `'writer'`.
  final String job;

  /// The character played, for actors.
  final String? character;
  final int sortOrder;
  const LibraryCreditRow({
    required this.itemId,
    required this.personId,
    required this.job,
    this.character,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['item_id'] = Variable<int>(itemId);
    map['person_id'] = Variable<int>(personId);
    map['job'] = Variable<String>(job);
    if (!nullToAbsent || character != null) {
      map['character'] = Variable<String>(character);
    }
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  LibraryCreditsCompanion toCompanion(bool nullToAbsent) {
    return LibraryCreditsCompanion(
      itemId: Value(itemId),
      personId: Value(personId),
      job: Value(job),
      character: character == null && nullToAbsent
          ? const Value.absent()
          : Value(character),
      sortOrder: Value(sortOrder),
    );
  }

  factory LibraryCreditRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryCreditRow(
      itemId: serializer.fromJson<int>(json['itemId']),
      personId: serializer.fromJson<int>(json['personId']),
      job: serializer.fromJson<String>(json['job']),
      character: serializer.fromJson<String?>(json['character']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'itemId': serializer.toJson<int>(itemId),
      'personId': serializer.toJson<int>(personId),
      'job': serializer.toJson<String>(job),
      'character': serializer.toJson<String?>(character),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  LibraryCreditRow copyWith({
    int? itemId,
    int? personId,
    String? job,
    Value<String?> character = const Value.absent(),
    int? sortOrder,
  }) => LibraryCreditRow(
    itemId: itemId ?? this.itemId,
    personId: personId ?? this.personId,
    job: job ?? this.job,
    character: character.present ? character.value : this.character,
    sortOrder: sortOrder ?? this.sortOrder,
  );
  LibraryCreditRow copyWithCompanion(LibraryCreditsCompanion data) {
    return LibraryCreditRow(
      itemId: data.itemId.present ? data.itemId.value : this.itemId,
      personId: data.personId.present ? data.personId.value : this.personId,
      job: data.job.present ? data.job.value : this.job,
      character: data.character.present ? data.character.value : this.character,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryCreditRow(')
          ..write('itemId: $itemId, ')
          ..write('personId: $personId, ')
          ..write('job: $job, ')
          ..write('character: $character, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(itemId, personId, job, character, sortOrder);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryCreditRow &&
          other.itemId == this.itemId &&
          other.personId == this.personId &&
          other.job == this.job &&
          other.character == this.character &&
          other.sortOrder == this.sortOrder);
}

class LibraryCreditsCompanion extends UpdateCompanion<LibraryCreditRow> {
  final Value<int> itemId;
  final Value<int> personId;
  final Value<String> job;
  final Value<String?> character;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const LibraryCreditsCompanion({
    this.itemId = const Value.absent(),
    this.personId = const Value.absent(),
    this.job = const Value.absent(),
    this.character = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibraryCreditsCompanion.insert({
    required int itemId,
    required int personId,
    required String job,
    this.character = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : itemId = Value(itemId),
       personId = Value(personId),
       job = Value(job);
  static Insertable<LibraryCreditRow> custom({
    Expression<int>? itemId,
    Expression<int>? personId,
    Expression<String>? job,
    Expression<String>? character,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (itemId != null) 'item_id': itemId,
      if (personId != null) 'person_id': personId,
      if (job != null) 'job': job,
      if (character != null) 'character': character,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibraryCreditsCompanion copyWith({
    Value<int>? itemId,
    Value<int>? personId,
    Value<String>? job,
    Value<String?>? character,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return LibraryCreditsCompanion(
      itemId: itemId ?? this.itemId,
      personId: personId ?? this.personId,
      job: job ?? this.job,
      character: character ?? this.character,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (itemId.present) {
      map['item_id'] = Variable<int>(itemId.value);
    }
    if (personId.present) {
      map['person_id'] = Variable<int>(personId.value);
    }
    if (job.present) {
      map['job'] = Variable<String>(job.value);
    }
    if (character.present) {
      map['character'] = Variable<String>(character.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryCreditsCompanion(')
          ..write('itemId: $itemId, ')
          ..write('personId: $personId, ')
          ..write('job: $job, ')
          ..write('character: $character, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LibraryListsTable extends LibraryLists
    with TableInfo<$LibraryListsTable, LibraryListRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryListsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _summaryMeta = const VerificationMeta(
    'summary',
  );
  @override
  late final GeneratedColumn<String> summary = GeneratedColumn<String>(
    'summary',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _posterSourceMeta = const VerificationMeta(
    'posterSource',
  );
  @override
  late final GeneratedColumn<String> posterSource = GeneratedColumn<String>(
    'poster_source',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _tmdbIdMeta = const VerificationMeta('tmdbId');
  @override
  late final GeneratedColumn<String> tmdbId = GeneratedColumn<String>(
    'tmdb_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta(
    'createdAt',
  );
  @override
  late final GeneratedColumn<int> createdAt = GeneratedColumn<int>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta(
    'updatedAt',
  );
  @override
  late final GeneratedColumn<int> updatedAt = GeneratedColumn<int>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    kind,
    title,
    summary,
    posterSource,
    tmdbId,
    createdAt,
    updatedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_lists';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryListRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('kind')) {
      context.handle(
        _kindMeta,
        kind.isAcceptableOrUnknown(data['kind']!, _kindMeta),
      );
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('summary')) {
      context.handle(
        _summaryMeta,
        summary.isAcceptableOrUnknown(data['summary']!, _summaryMeta),
      );
    }
    if (data.containsKey('poster_source')) {
      context.handle(
        _posterSourceMeta,
        posterSource.isAcceptableOrUnknown(
          data['poster_source']!,
          _posterSourceMeta,
        ),
      );
    }
    if (data.containsKey('tmdb_id')) {
      context.handle(
        _tmdbIdMeta,
        tmdbId.isAcceptableOrUnknown(data['tmdb_id']!, _tmdbIdMeta),
      );
    }
    if (data.containsKey('created_at')) {
      context.handle(
        _createdAtMeta,
        createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta),
      );
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(
        _updatedAtMeta,
        updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LibraryListRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryListRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      kind: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}kind'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      summary: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}summary'],
      ),
      posterSource: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}poster_source'],
      ),
      tmdbId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}tmdb_id'],
      ),
      createdAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}created_at'],
      )!,
      updatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}updated_at'],
      )!,
    );
  }

  @override
  $LibraryListsTable createAlias(String alias) {
    return $LibraryListsTable(attachedDatabase, alias);
  }
}

class LibraryListRow extends DataClass implements Insertable<LibraryListRow> {
  final int id;

  /// `'collection'` or `'playlist'`.
  final String kind;
  final String title;
  final String? summary;
  final String? posterSource;

  /// TMDB collection id when the scraper created it; null for the user's own.
  final String? tmdbId;
  final int createdAt;
  final int updatedAt;
  const LibraryListRow({
    required this.id,
    required this.kind,
    required this.title,
    this.summary,
    this.posterSource,
    this.tmdbId,
    required this.createdAt,
    required this.updatedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['kind'] = Variable<String>(kind);
    map['title'] = Variable<String>(title);
    if (!nullToAbsent || summary != null) {
      map['summary'] = Variable<String>(summary);
    }
    if (!nullToAbsent || posterSource != null) {
      map['poster_source'] = Variable<String>(posterSource);
    }
    if (!nullToAbsent || tmdbId != null) {
      map['tmdb_id'] = Variable<String>(tmdbId);
    }
    map['created_at'] = Variable<int>(createdAt);
    map['updated_at'] = Variable<int>(updatedAt);
    return map;
  }

  LibraryListsCompanion toCompanion(bool nullToAbsent) {
    return LibraryListsCompanion(
      id: Value(id),
      kind: Value(kind),
      title: Value(title),
      summary: summary == null && nullToAbsent
          ? const Value.absent()
          : Value(summary),
      posterSource: posterSource == null && nullToAbsent
          ? const Value.absent()
          : Value(posterSource),
      tmdbId: tmdbId == null && nullToAbsent
          ? const Value.absent()
          : Value(tmdbId),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
    );
  }

  factory LibraryListRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryListRow(
      id: serializer.fromJson<int>(json['id']),
      kind: serializer.fromJson<String>(json['kind']),
      title: serializer.fromJson<String>(json['title']),
      summary: serializer.fromJson<String?>(json['summary']),
      posterSource: serializer.fromJson<String?>(json['posterSource']),
      tmdbId: serializer.fromJson<String?>(json['tmdbId']),
      createdAt: serializer.fromJson<int>(json['createdAt']),
      updatedAt: serializer.fromJson<int>(json['updatedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'kind': serializer.toJson<String>(kind),
      'title': serializer.toJson<String>(title),
      'summary': serializer.toJson<String?>(summary),
      'posterSource': serializer.toJson<String?>(posterSource),
      'tmdbId': serializer.toJson<String?>(tmdbId),
      'createdAt': serializer.toJson<int>(createdAt),
      'updatedAt': serializer.toJson<int>(updatedAt),
    };
  }

  LibraryListRow copyWith({
    int? id,
    String? kind,
    String? title,
    Value<String?> summary = const Value.absent(),
    Value<String?> posterSource = const Value.absent(),
    Value<String?> tmdbId = const Value.absent(),
    int? createdAt,
    int? updatedAt,
  }) => LibraryListRow(
    id: id ?? this.id,
    kind: kind ?? this.kind,
    title: title ?? this.title,
    summary: summary.present ? summary.value : this.summary,
    posterSource: posterSource.present ? posterSource.value : this.posterSource,
    tmdbId: tmdbId.present ? tmdbId.value : this.tmdbId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
  );
  LibraryListRow copyWithCompanion(LibraryListsCompanion data) {
    return LibraryListRow(
      id: data.id.present ? data.id.value : this.id,
      kind: data.kind.present ? data.kind.value : this.kind,
      title: data.title.present ? data.title.value : this.title,
      summary: data.summary.present ? data.summary.value : this.summary,
      posterSource: data.posterSource.present
          ? data.posterSource.value
          : this.posterSource,
      tmdbId: data.tmdbId.present ? data.tmdbId.value : this.tmdbId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryListRow(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('title: $title, ')
          ..write('summary: $summary, ')
          ..write('posterSource: $posterSource, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    kind,
    title,
    summary,
    posterSource,
    tmdbId,
    createdAt,
    updatedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryListRow &&
          other.id == this.id &&
          other.kind == this.kind &&
          other.title == this.title &&
          other.summary == this.summary &&
          other.posterSource == this.posterSource &&
          other.tmdbId == this.tmdbId &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt);
}

class LibraryListsCompanion extends UpdateCompanion<LibraryListRow> {
  final Value<int> id;
  final Value<String> kind;
  final Value<String> title;
  final Value<String?> summary;
  final Value<String?> posterSource;
  final Value<String?> tmdbId;
  final Value<int> createdAt;
  final Value<int> updatedAt;
  const LibraryListsCompanion({
    this.id = const Value.absent(),
    this.kind = const Value.absent(),
    this.title = const Value.absent(),
    this.summary = const Value.absent(),
    this.posterSource = const Value.absent(),
    this.tmdbId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
  });
  LibraryListsCompanion.insert({
    this.id = const Value.absent(),
    required String kind,
    required String title,
    this.summary = const Value.absent(),
    this.posterSource = const Value.absent(),
    this.tmdbId = const Value.absent(),
    required int createdAt,
    required int updatedAt,
  }) : kind = Value(kind),
       title = Value(title),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<LibraryListRow> custom({
    Expression<int>? id,
    Expression<String>? kind,
    Expression<String>? title,
    Expression<String>? summary,
    Expression<String>? posterSource,
    Expression<String>? tmdbId,
    Expression<int>? createdAt,
    Expression<int>? updatedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (kind != null) 'kind': kind,
      if (title != null) 'title': title,
      if (summary != null) 'summary': summary,
      if (posterSource != null) 'poster_source': posterSource,
      if (tmdbId != null) 'tmdb_id': tmdbId,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
    });
  }

  LibraryListsCompanion copyWith({
    Value<int>? id,
    Value<String>? kind,
    Value<String>? title,
    Value<String?>? summary,
    Value<String?>? posterSource,
    Value<String?>? tmdbId,
    Value<int>? createdAt,
    Value<int>? updatedAt,
  }) {
    return LibraryListsCompanion(
      id: id ?? this.id,
      kind: kind ?? this.kind,
      title: title ?? this.title,
      summary: summary ?? this.summary,
      posterSource: posterSource ?? this.posterSource,
      tmdbId: tmdbId ?? this.tmdbId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (summary.present) {
      map['summary'] = Variable<String>(summary.value);
    }
    if (posterSource.present) {
      map['poster_source'] = Variable<String>(posterSource.value);
    }
    if (tmdbId.present) {
      map['tmdb_id'] = Variable<String>(tmdbId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<int>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<int>(updatedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryListsCompanion(')
          ..write('id: $id, ')
          ..write('kind: $kind, ')
          ..write('title: $title, ')
          ..write('summary: $summary, ')
          ..write('posterSource: $posterSource, ')
          ..write('tmdbId: $tmdbId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt')
          ..write(')'))
        .toString();
  }
}

class $LibraryListItemsTable extends LibraryListItems
    with TableInfo<$LibraryListItemsTable, LibraryListItemRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryListItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _listIdMeta = const VerificationMeta('listId');
  @override
  late final GeneratedColumn<int> listId = GeneratedColumn<int>(
    'list_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_lists (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _itemIdMeta = const VerificationMeta('itemId');
  @override
  late final GeneratedColumn<int> itemId = GeneratedColumn<int>(
    'item_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES library_items (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _sortOrderMeta = const VerificationMeta(
    'sortOrder',
  );
  @override
  late final GeneratedColumn<int> sortOrder = GeneratedColumn<int>(
    'sort_order',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  @override
  List<GeneratedColumn> get $columns => [listId, itemId, sortOrder];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_list_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryListItemRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('list_id')) {
      context.handle(
        _listIdMeta,
        listId.isAcceptableOrUnknown(data['list_id']!, _listIdMeta),
      );
    } else if (isInserting) {
      context.missing(_listIdMeta);
    }
    if (data.containsKey('item_id')) {
      context.handle(
        _itemIdMeta,
        itemId.isAcceptableOrUnknown(data['item_id']!, _itemIdMeta),
      );
    } else if (isInserting) {
      context.missing(_itemIdMeta);
    }
    if (data.containsKey('sort_order')) {
      context.handle(
        _sortOrderMeta,
        sortOrder.isAcceptableOrUnknown(data['sort_order']!, _sortOrderMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {listId, itemId};
  @override
  LibraryListItemRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryListItemRow(
      listId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}list_id'],
      )!,
      itemId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}item_id'],
      )!,
      sortOrder: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}sort_order'],
      )!,
    );
  }

  @override
  $LibraryListItemsTable createAlias(String alias) {
    return $LibraryListItemsTable(attachedDatabase, alias);
  }
}

class LibraryListItemRow extends DataClass
    implements Insertable<LibraryListItemRow> {
  final int listId;
  final int itemId;
  final int sortOrder;
  const LibraryListItemRow({
    required this.listId,
    required this.itemId,
    required this.sortOrder,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['list_id'] = Variable<int>(listId);
    map['item_id'] = Variable<int>(itemId);
    map['sort_order'] = Variable<int>(sortOrder);
    return map;
  }

  LibraryListItemsCompanion toCompanion(bool nullToAbsent) {
    return LibraryListItemsCompanion(
      listId: Value(listId),
      itemId: Value(itemId),
      sortOrder: Value(sortOrder),
    );
  }

  factory LibraryListItemRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryListItemRow(
      listId: serializer.fromJson<int>(json['listId']),
      itemId: serializer.fromJson<int>(json['itemId']),
      sortOrder: serializer.fromJson<int>(json['sortOrder']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'listId': serializer.toJson<int>(listId),
      'itemId': serializer.toJson<int>(itemId),
      'sortOrder': serializer.toJson<int>(sortOrder),
    };
  }

  LibraryListItemRow copyWith({int? listId, int? itemId, int? sortOrder}) =>
      LibraryListItemRow(
        listId: listId ?? this.listId,
        itemId: itemId ?? this.itemId,
        sortOrder: sortOrder ?? this.sortOrder,
      );
  LibraryListItemRow copyWithCompanion(LibraryListItemsCompanion data) {
    return LibraryListItemRow(
      listId: data.listId.present ? data.listId.value : this.listId,
      itemId: data.itemId.present ? data.itemId.value : this.itemId,
      sortOrder: data.sortOrder.present ? data.sortOrder.value : this.sortOrder,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryListItemRow(')
          ..write('listId: $listId, ')
          ..write('itemId: $itemId, ')
          ..write('sortOrder: $sortOrder')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(listId, itemId, sortOrder);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryListItemRow &&
          other.listId == this.listId &&
          other.itemId == this.itemId &&
          other.sortOrder == this.sortOrder);
}

class LibraryListItemsCompanion extends UpdateCompanion<LibraryListItemRow> {
  final Value<int> listId;
  final Value<int> itemId;
  final Value<int> sortOrder;
  final Value<int> rowid;
  const LibraryListItemsCompanion({
    this.listId = const Value.absent(),
    this.itemId = const Value.absent(),
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibraryListItemsCompanion.insert({
    required int listId,
    required int itemId,
    this.sortOrder = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : listId = Value(listId),
       itemId = Value(itemId);
  static Insertable<LibraryListItemRow> custom({
    Expression<int>? listId,
    Expression<int>? itemId,
    Expression<int>? sortOrder,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (listId != null) 'list_id': listId,
      if (itemId != null) 'item_id': itemId,
      if (sortOrder != null) 'sort_order': sortOrder,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibraryListItemsCompanion copyWith({
    Value<int>? listId,
    Value<int>? itemId,
    Value<int>? sortOrder,
    Value<int>? rowid,
  }) {
    return LibraryListItemsCompanion(
      listId: listId ?? this.listId,
      itemId: itemId ?? this.itemId,
      sortOrder: sortOrder ?? this.sortOrder,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (listId.present) {
      map['list_id'] = Variable<int>(listId.value);
    }
    if (itemId.present) {
      map['item_id'] = Variable<int>(itemId.value);
    }
    if (sortOrder.present) {
      map['sort_order'] = Variable<int>(sortOrder.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryListItemsCompanion(')
          ..write('listId: $listId, ')
          ..write('itemId: $itemId, ')
          ..write('sortOrder: $sortOrder, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LibraryScanStatesTable extends LibraryScanStates
    with TableInfo<$LibraryScanStatesTable, LibraryScanStateRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryScanStatesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _mountIdMeta = const VerificationMeta(
    'mountId',
  );
  @override
  late final GeneratedColumn<String> mountId = GeneratedColumn<String>(
    'mount_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'REFERENCES mounts (id) ON DELETE CASCADE',
    ),
  );
  static const VerificationMeta _scanIdMeta = const VerificationMeta('scanId');
  @override
  late final GeneratedColumn<int> scanId = GeneratedColumn<int>(
    'scan_id',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('idle'),
  );
  static const VerificationMeta _pendingMeta = const VerificationMeta(
    'pending',
  );
  @override
  late final GeneratedColumn<String> pending = GeneratedColumn<String>(
    'pending',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _startedAtMeta = const VerificationMeta(
    'startedAt',
  );
  @override
  late final GeneratedColumn<int> startedAt = GeneratedColumn<int>(
    'started_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _finishedAtMeta = const VerificationMeta(
    'finishedAt',
  );
  @override
  late final GeneratedColumn<int> finishedAt = GeneratedColumn<int>(
    'finished_at',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastErrorMeta = const VerificationMeta(
    'lastError',
  );
  @override
  late final GeneratedColumn<String> lastError = GeneratedColumn<String>(
    'last_error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    mountId,
    scanId,
    status,
    pending,
    startedAt,
    finishedAt,
    lastError,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_scan_states';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibraryScanStateRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('mount_id')) {
      context.handle(
        _mountIdMeta,
        mountId.isAcceptableOrUnknown(data['mount_id']!, _mountIdMeta),
      );
    } else if (isInserting) {
      context.missing(_mountIdMeta);
    }
    if (data.containsKey('scan_id')) {
      context.handle(
        _scanIdMeta,
        scanId.isAcceptableOrUnknown(data['scan_id']!, _scanIdMeta),
      );
    }
    if (data.containsKey('status')) {
      context.handle(
        _statusMeta,
        status.isAcceptableOrUnknown(data['status']!, _statusMeta),
      );
    }
    if (data.containsKey('pending')) {
      context.handle(
        _pendingMeta,
        pending.isAcceptableOrUnknown(data['pending']!, _pendingMeta),
      );
    }
    if (data.containsKey('started_at')) {
      context.handle(
        _startedAtMeta,
        startedAt.isAcceptableOrUnknown(data['started_at']!, _startedAtMeta),
      );
    }
    if (data.containsKey('finished_at')) {
      context.handle(
        _finishedAtMeta,
        finishedAt.isAcceptableOrUnknown(data['finished_at']!, _finishedAtMeta),
      );
    }
    if (data.containsKey('last_error')) {
      context.handle(
        _lastErrorMeta,
        lastError.isAcceptableOrUnknown(data['last_error']!, _lastErrorMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {mountId};
  @override
  LibraryScanStateRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryScanStateRow(
      mountId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}mount_id'],
      )!,
      scanId: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}scan_id'],
      )!,
      status: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}status'],
      )!,
      pending: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}pending'],
      ),
      startedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}started_at'],
      ),
      finishedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}finished_at'],
      ),
      lastError: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}last_error'],
      ),
    );
  }

  @override
  $LibraryScanStatesTable createAlias(String alias) {
    return $LibraryScanStatesTable(attachedDatabase, alias);
  }
}

class LibraryScanStateRow extends DataClass
    implements Insertable<LibraryScanStateRow> {
  final String mountId;

  /// Incremented each time a scan starts; stamped on the files it sees.
  final int scanId;

  /// `'idle'`, `'running'` or `'failed'`.
  final String status;

  /// Directories still to visit, as a JSON array, while a scan is running.
  final String? pending;
  final int? startedAt;
  final int? finishedAt;
  final String? lastError;
  const LibraryScanStateRow({
    required this.mountId,
    required this.scanId,
    required this.status,
    this.pending,
    this.startedAt,
    this.finishedAt,
    this.lastError,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['mount_id'] = Variable<String>(mountId);
    map['scan_id'] = Variable<int>(scanId);
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || pending != null) {
      map['pending'] = Variable<String>(pending);
    }
    if (!nullToAbsent || startedAt != null) {
      map['started_at'] = Variable<int>(startedAt);
    }
    if (!nullToAbsent || finishedAt != null) {
      map['finished_at'] = Variable<int>(finishedAt);
    }
    if (!nullToAbsent || lastError != null) {
      map['last_error'] = Variable<String>(lastError);
    }
    return map;
  }

  LibraryScanStatesCompanion toCompanion(bool nullToAbsent) {
    return LibraryScanStatesCompanion(
      mountId: Value(mountId),
      scanId: Value(scanId),
      status: Value(status),
      pending: pending == null && nullToAbsent
          ? const Value.absent()
          : Value(pending),
      startedAt: startedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(startedAt),
      finishedAt: finishedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(finishedAt),
      lastError: lastError == null && nullToAbsent
          ? const Value.absent()
          : Value(lastError),
    );
  }

  factory LibraryScanStateRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryScanStateRow(
      mountId: serializer.fromJson<String>(json['mountId']),
      scanId: serializer.fromJson<int>(json['scanId']),
      status: serializer.fromJson<String>(json['status']),
      pending: serializer.fromJson<String?>(json['pending']),
      startedAt: serializer.fromJson<int?>(json['startedAt']),
      finishedAt: serializer.fromJson<int?>(json['finishedAt']),
      lastError: serializer.fromJson<String?>(json['lastError']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'mountId': serializer.toJson<String>(mountId),
      'scanId': serializer.toJson<int>(scanId),
      'status': serializer.toJson<String>(status),
      'pending': serializer.toJson<String?>(pending),
      'startedAt': serializer.toJson<int?>(startedAt),
      'finishedAt': serializer.toJson<int?>(finishedAt),
      'lastError': serializer.toJson<String?>(lastError),
    };
  }

  LibraryScanStateRow copyWith({
    String? mountId,
    int? scanId,
    String? status,
    Value<String?> pending = const Value.absent(),
    Value<int?> startedAt = const Value.absent(),
    Value<int?> finishedAt = const Value.absent(),
    Value<String?> lastError = const Value.absent(),
  }) => LibraryScanStateRow(
    mountId: mountId ?? this.mountId,
    scanId: scanId ?? this.scanId,
    status: status ?? this.status,
    pending: pending.present ? pending.value : this.pending,
    startedAt: startedAt.present ? startedAt.value : this.startedAt,
    finishedAt: finishedAt.present ? finishedAt.value : this.finishedAt,
    lastError: lastError.present ? lastError.value : this.lastError,
  );
  LibraryScanStateRow copyWithCompanion(LibraryScanStatesCompanion data) {
    return LibraryScanStateRow(
      mountId: data.mountId.present ? data.mountId.value : this.mountId,
      scanId: data.scanId.present ? data.scanId.value : this.scanId,
      status: data.status.present ? data.status.value : this.status,
      pending: data.pending.present ? data.pending.value : this.pending,
      startedAt: data.startedAt.present ? data.startedAt.value : this.startedAt,
      finishedAt: data.finishedAt.present
          ? data.finishedAt.value
          : this.finishedAt,
      lastError: data.lastError.present ? data.lastError.value : this.lastError,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryScanStateRow(')
          ..write('mountId: $mountId, ')
          ..write('scanId: $scanId, ')
          ..write('status: $status, ')
          ..write('pending: $pending, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('lastError: $lastError')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    mountId,
    scanId,
    status,
    pending,
    startedAt,
    finishedAt,
    lastError,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryScanStateRow &&
          other.mountId == this.mountId &&
          other.scanId == this.scanId &&
          other.status == this.status &&
          other.pending == this.pending &&
          other.startedAt == this.startedAt &&
          other.finishedAt == this.finishedAt &&
          other.lastError == this.lastError);
}

class LibraryScanStatesCompanion extends UpdateCompanion<LibraryScanStateRow> {
  final Value<String> mountId;
  final Value<int> scanId;
  final Value<String> status;
  final Value<String?> pending;
  final Value<int?> startedAt;
  final Value<int?> finishedAt;
  final Value<String?> lastError;
  final Value<int> rowid;
  const LibraryScanStatesCompanion({
    this.mountId = const Value.absent(),
    this.scanId = const Value.absent(),
    this.status = const Value.absent(),
    this.pending = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
    this.lastError = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibraryScanStatesCompanion.insert({
    required String mountId,
    this.scanId = const Value.absent(),
    this.status = const Value.absent(),
    this.pending = const Value.absent(),
    this.startedAt = const Value.absent(),
    this.finishedAt = const Value.absent(),
    this.lastError = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : mountId = Value(mountId);
  static Insertable<LibraryScanStateRow> custom({
    Expression<String>? mountId,
    Expression<int>? scanId,
    Expression<String>? status,
    Expression<String>? pending,
    Expression<int>? startedAt,
    Expression<int>? finishedAt,
    Expression<String>? lastError,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (mountId != null) 'mount_id': mountId,
      if (scanId != null) 'scan_id': scanId,
      if (status != null) 'status': status,
      if (pending != null) 'pending': pending,
      if (startedAt != null) 'started_at': startedAt,
      if (finishedAt != null) 'finished_at': finishedAt,
      if (lastError != null) 'last_error': lastError,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibraryScanStatesCompanion copyWith({
    Value<String>? mountId,
    Value<int>? scanId,
    Value<String>? status,
    Value<String?>? pending,
    Value<int?>? startedAt,
    Value<int?>? finishedAt,
    Value<String?>? lastError,
    Value<int>? rowid,
  }) {
    return LibraryScanStatesCompanion(
      mountId: mountId ?? this.mountId,
      scanId: scanId ?? this.scanId,
      status: status ?? this.status,
      pending: pending ?? this.pending,
      startedAt: startedAt ?? this.startedAt,
      finishedAt: finishedAt ?? this.finishedAt,
      lastError: lastError ?? this.lastError,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (mountId.present) {
      map['mount_id'] = Variable<String>(mountId.value);
    }
    if (scanId.present) {
      map['scan_id'] = Variable<int>(scanId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (pending.present) {
      map['pending'] = Variable<String>(pending.value);
    }
    if (startedAt.present) {
      map['started_at'] = Variable<int>(startedAt.value);
    }
    if (finishedAt.present) {
      map['finished_at'] = Variable<int>(finishedAt.value);
    }
    if (lastError.present) {
      map['last_error'] = Variable<String>(lastError.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryScanStatesCompanion(')
          ..write('mountId: $mountId, ')
          ..write('scanId: $scanId, ')
          ..write('status: $status, ')
          ..write('pending: $pending, ')
          ..write('startedAt: $startedAt, ')
          ..write('finishedAt: $finishedAt, ')
          ..write('lastError: $lastError, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LibrarySettingsTable extends LibrarySettings
    with TableInfo<$LibrarySettingsTable, LibrarySettingRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibrarySettingsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_settings';
  @override
  VerificationContext validateIntegrity(
    Insertable<LibrarySettingRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  LibrarySettingRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibrarySettingRow(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $LibrarySettingsTable createAlias(String alias) {
    return $LibrarySettingsTable(attachedDatabase, alias);
  }
}

class LibrarySettingRow extends DataClass
    implements Insertable<LibrarySettingRow> {
  final String key;
  final String value;
  const LibrarySettingRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  LibrarySettingsCompanion toCompanion(bool nullToAbsent) {
    return LibrarySettingsCompanion(key: Value(key), value: Value(value));
  }

  factory LibrarySettingRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibrarySettingRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  LibrarySettingRow copyWith({String? key, String? value}) =>
      LibrarySettingRow(key: key ?? this.key, value: value ?? this.value);
  LibrarySettingRow copyWithCompanion(LibrarySettingsCompanion data) {
    return LibrarySettingRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibrarySettingRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibrarySettingRow &&
          other.key == this.key &&
          other.value == this.value);
}

class LibrarySettingsCompanion extends UpdateCompanion<LibrarySettingRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const LibrarySettingsCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibrarySettingsCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<LibrarySettingRow> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibrarySettingsCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return LibrarySettingsCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibrarySettingsCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $DownloadedMediaTable downloadedMedia = $DownloadedMediaTable(
    this,
  );
  late final $DownloadOwnersTable downloadOwners = $DownloadOwnersTable(this);
  late final $DownloadQueueTable downloadQueue = $DownloadQueueTable(this);
  late final $ApiCacheTable apiCache = $ApiCacheTable(this);
  late final $OfflineWatchProgressTable offlineWatchProgress =
      $OfflineWatchProgressTable(this);
  late final $SyncRulesTable syncRules = $SyncRulesTable(this);
  late final $SyncRuleDownloadsTable syncRuleDownloads =
      $SyncRuleDownloadsTable(this);
  late final $DownloadCollectionsTable downloadCollections =
      $DownloadCollectionsTable(this);
  late final $DownloadCollectionSyncsTable downloadCollectionSyncs =
      $DownloadCollectionSyncsTable(this);
  late final $ConnectionsTable connections = $ConnectionsTable(this);
  late final $ProfilesTable profiles = $ProfilesTable(this);
  late final $ProfileConnectionsTable profileConnections =
      $ProfileConnectionsTable(this);
  late final $MusicSessionsTable musicSessions = $MusicSessionsTable(this);
  late final $MountsTable mounts = $MountsTable(this);
  late final $LibraryItemsTable libraryItems = $LibraryItemsTable(this);
  late final $LibraryFilesTable libraryFiles = $LibraryFilesTable(this);
  late final $LibraryUserStatesTable libraryUserStates =
      $LibraryUserStatesTable(this);
  late final $LibraryGenresTable libraryGenres = $LibraryGenresTable(this);
  late final $LibraryItemGenresTable libraryItemGenres =
      $LibraryItemGenresTable(this);
  late final $LibraryPeopleTable libraryPeople = $LibraryPeopleTable(this);
  late final $LibraryCreditsTable libraryCredits = $LibraryCreditsTable(this);
  late final $LibraryListsTable libraryLists = $LibraryListsTable(this);
  late final $LibraryListItemsTable libraryListItems = $LibraryListItemsTable(
    this,
  );
  late final $LibraryScanStatesTable libraryScanStates =
      $LibraryScanStatesTable(this);
  late final $LibrarySettingsTable librarySettings = $LibrarySettingsTable(
    this,
  );
  late final Index idxDownloadedMediaStatus = Index(
    'idx_downloaded_media_status',
    'CREATE INDEX idx_downloaded_media_status ON downloaded_media (status)',
  );
  late final Index idxDownloadedMediaServer = Index(
    'idx_downloaded_media_server',
    'CREATE INDEX idx_downloaded_media_server ON downloaded_media (server_id)',
  );
  late final Index idxDownloadedMediaParent = Index(
    'idx_downloaded_media_parent',
    'CREATE INDEX idx_downloaded_media_parent ON downloaded_media (parent_rating_key)',
  );
  late final Index idxDownloadedMediaGrandparent = Index(
    'idx_downloaded_media_grandparent',
    'CREATE INDEX idx_downloaded_media_grandparent ON downloaded_media (grandparent_rating_key)',
  );
  late final Index idxDownloadOwnersProfile = Index(
    'idx_download_owners_profile',
    'CREATE INDEX idx_download_owners_profile ON download_owners (profile_id)',
  );
  late final Index idxDownloadOwnersGlobalKey = Index(
    'idx_download_owners_global_key',
    'CREATE INDEX idx_download_owners_global_key ON download_owners (global_key)',
  );
  late final Index idxOfflineWatchProgressServer = Index(
    'idx_offline_watch_progress_server',
    'CREATE INDEX idx_offline_watch_progress_server ON offline_watch_progress (server_id)',
  );
  late final Index idxOfflineWatchProgressProfile = Index(
    'idx_offline_watch_progress_profile',
    'CREATE INDEX idx_offline_watch_progress_profile ON offline_watch_progress (profile_id)',
  );
  late final Index idxSyncRulesProfile = Index(
    'idx_sync_rules_profile',
    'CREATE INDEX idx_sync_rules_profile ON sync_rules (profile_id)',
  );
  late final Index idxSyncRuleDownloadsProfileKey = Index(
    'idx_sync_rule_downloads_profile_key',
    'CREATE INDEX idx_sync_rule_downloads_profile_key ON sync_rule_downloads (profile_id, download_global_key)',
  );
  late final Index idxConnectionsKind = Index(
    'idx_connections_kind',
    'CREATE INDEX idx_connections_kind ON connections (kind)',
  );
  late final Index idxProfilesKind = Index(
    'idx_profiles_kind',
    'CREATE INDEX idx_profiles_kind ON profiles (kind)',
  );
  late final Index idxProfileConnectionsConnectionId = Index(
    'idx_profile_connections_connection_id',
    'CREATE INDEX idx_profile_connections_connection_id ON profile_connections (connection_id)',
  );
  late final Index idxProfileConnectionsProfileId = Index(
    'idx_profile_connections_profile_id',
    'CREATE INDEX idx_profile_connections_profile_id ON profile_connections (profile_id)',
  );
  late final Index idxLibraryItemsKindType = Index(
    'idx_library_items_kind_type',
    'CREATE INDEX idx_library_items_kind_type ON library_items (kind, library_type)',
  );
  late final Index idxLibraryItemsParent = Index(
    'idx_library_items_parent',
    'CREATE INDEX idx_library_items_parent ON library_items (parent_id)',
  );
  late final Index idxLibraryItemsShow = Index(
    'idx_library_items_show',
    'CREATE INDEX idx_library_items_show ON library_items (show_id)',
  );
  late final Index idxLibraryItemsTmdb = Index(
    'idx_library_items_tmdb',
    'CREATE INDEX idx_library_items_tmdb ON library_items (kind, tmdb_id)',
  );
  late final Index idxLibraryItemsAdded = Index(
    'idx_library_items_added',
    'CREATE INDEX idx_library_items_added ON library_items (added_at)',
  );
  late final Index idxLibraryFilesMountPath = Index(
    'idx_library_files_mount_path',
    'CREATE UNIQUE INDEX idx_library_files_mount_path ON library_files (mount_id, path)',
  );
  late final Index idxLibraryFilesItem = Index(
    'idx_library_files_item',
    'CREATE INDEX idx_library_files_item ON library_files (item_id)',
  );
  late final Index idxLibraryFilesMatch = Index(
    'idx_library_files_match',
    'CREATE INDEX idx_library_files_match ON library_files (role, match_state)',
  );
  late final Index idxLibraryFilesOwner = Index(
    'idx_library_files_owner',
    'CREATE INDEX idx_library_files_owner ON library_files (owner_file_id)',
  );
  late final Index idxLibraryUserStatesPlayed = Index(
    'idx_library_user_states_played',
    'CREATE INDEX idx_library_user_states_played ON library_user_states (last_played_at)',
  );
  late final Index idxLibraryItemGenresGenre = Index(
    'idx_library_item_genres_genre',
    'CREATE INDEX idx_library_item_genres_genre ON library_item_genres (genre_id)',
  );
  late final Index idxLibraryPeopleTmdb = Index(
    'idx_library_people_tmdb',
    'CREATE INDEX idx_library_people_tmdb ON library_people (tmdb_id)',
  );
  late final Index idxLibraryCreditsPerson = Index(
    'idx_library_credits_person',
    'CREATE INDEX idx_library_credits_person ON library_credits (person_id)',
  );
  late final Index idxLibraryListItemsItem = Index(
    'idx_library_list_items_item',
    'CREATE INDEX idx_library_list_items_item ON library_list_items (item_id)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    downloadedMedia,
    downloadOwners,
    downloadQueue,
    apiCache,
    offlineWatchProgress,
    syncRules,
    syncRuleDownloads,
    downloadCollections,
    downloadCollectionSyncs,
    connections,
    profiles,
    profileConnections,
    musicSessions,
    mounts,
    libraryItems,
    libraryFiles,
    libraryUserStates,
    libraryGenres,
    libraryItemGenres,
    libraryPeople,
    libraryCredits,
    libraryLists,
    libraryListItems,
    libraryScanStates,
    librarySettings,
    idxDownloadedMediaStatus,
    idxDownloadedMediaServer,
    idxDownloadedMediaParent,
    idxDownloadedMediaGrandparent,
    idxDownloadOwnersProfile,
    idxDownloadOwnersGlobalKey,
    idxOfflineWatchProgressServer,
    idxOfflineWatchProgressProfile,
    idxSyncRulesProfile,
    idxSyncRuleDownloadsProfileKey,
    idxConnectionsKind,
    idxProfilesKind,
    idxProfileConnectionsConnectionId,
    idxProfileConnectionsProfileId,
    idxLibraryItemsKindType,
    idxLibraryItemsParent,
    idxLibraryItemsShow,
    idxLibraryItemsTmdb,
    idxLibraryItemsAdded,
    idxLibraryFilesMountPath,
    idxLibraryFilesItem,
    idxLibraryFilesMatch,
    idxLibraryFilesOwner,
    idxLibraryUserStatesPlayed,
    idxLibraryItemGenresGenre,
    idxLibraryPeopleTmdb,
    idxLibraryCreditsPerson,
    idxLibraryListItemsItem,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'sync_rules',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('sync_rule_downloads', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'connections',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('profile_connections', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_items',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_items', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_items',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_items', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'mounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_files', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_items',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_files', kind: UpdateKind.update)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_files',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_files', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_items',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_user_states', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_items',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_item_genres', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_genres',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_item_genres', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_items',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_credits', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_people',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_credits', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_lists',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_list_items', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'library_items',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_list_items', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName(
        'mounts',
        limitUpdateKind: UpdateKind.delete,
      ),
      result: [TableUpdate('library_scan_states', kind: UpdateKind.delete)],
    ),
  ]);
}

typedef $$DownloadedMediaTableCreateCompanionBuilder =
    DownloadedMediaCompanion Function({
      Value<int> id,
      required String serverId,
      Value<String?> clientScopeId,
      required String ratingKey,
      required String globalKey,
      required String type,
      Value<String?> parentRatingKey,
      Value<String?> grandparentRatingKey,
      required int status,
      Value<int> progress,
      Value<int?> totalBytes,
      Value<int> downloadedBytes,
      Value<String?> videoFilePath,
      Value<String?> additionalPartPaths,
      Value<String?> safRootUri,
      Value<String?> thumbPath,
      Value<int?> downloadedAt,
      Value<String?> errorMessage,
      Value<int> retryCount,
      Value<String?> bgTaskId,
      Value<int> mediaIndex,
      Value<String?> mediaSourceId,
      Value<String?> libraryId,
      Value<String?> libraryTitle,
    });
typedef $$DownloadedMediaTableUpdateCompanionBuilder =
    DownloadedMediaCompanion Function({
      Value<int> id,
      Value<String> serverId,
      Value<String?> clientScopeId,
      Value<String> ratingKey,
      Value<String> globalKey,
      Value<String> type,
      Value<String?> parentRatingKey,
      Value<String?> grandparentRatingKey,
      Value<int> status,
      Value<int> progress,
      Value<int?> totalBytes,
      Value<int> downloadedBytes,
      Value<String?> videoFilePath,
      Value<String?> additionalPartPaths,
      Value<String?> safRootUri,
      Value<String?> thumbPath,
      Value<int?> downloadedAt,
      Value<String?> errorMessage,
      Value<int> retryCount,
      Value<String?> bgTaskId,
      Value<int> mediaIndex,
      Value<String?> mediaSourceId,
      Value<String?> libraryId,
      Value<String?> libraryTitle,
    });

class $$DownloadedMediaTableFilterComposer
    extends Composer<_$AppDatabase, $DownloadedMediaTable> {
  $$DownloadedMediaTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get clientScopeId => $composableBuilder(
    column: $table.clientScopeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ratingKey => $composableBuilder(
    column: $table.ratingKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get globalKey => $composableBuilder(
    column: $table.globalKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parentRatingKey => $composableBuilder(
    column: $table.parentRatingKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get grandparentRatingKey => $composableBuilder(
    column: $table.grandparentRatingKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get videoFilePath => $composableBuilder(
    column: $table.videoFilePath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get additionalPartPaths => $composableBuilder(
    column: $table.additionalPartPaths,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get safRootUri => $composableBuilder(
    column: $table.safRootUri,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get thumbPath => $composableBuilder(
    column: $table.thumbPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bgTaskId => $composableBuilder(
    column: $table.bgTaskId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mediaIndex => $composableBuilder(
    column: $table.mediaIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mediaSourceId => $composableBuilder(
    column: $table.mediaSourceId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get libraryId => $composableBuilder(
    column: $table.libraryId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get libraryTitle => $composableBuilder(
    column: $table.libraryTitle,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DownloadedMediaTableOrderingComposer
    extends Composer<_$AppDatabase, $DownloadedMediaTable> {
  $$DownloadedMediaTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get clientScopeId => $composableBuilder(
    column: $table.clientScopeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ratingKey => $composableBuilder(
    column: $table.ratingKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get globalKey => $composableBuilder(
    column: $table.globalKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get type => $composableBuilder(
    column: $table.type,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parentRatingKey => $composableBuilder(
    column: $table.parentRatingKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get grandparentRatingKey => $composableBuilder(
    column: $table.grandparentRatingKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get progress => $composableBuilder(
    column: $table.progress,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get videoFilePath => $composableBuilder(
    column: $table.videoFilePath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get additionalPartPaths => $composableBuilder(
    column: $table.additionalPartPaths,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get safRootUri => $composableBuilder(
    column: $table.safRootUri,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get thumbPath => $composableBuilder(
    column: $table.thumbPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bgTaskId => $composableBuilder(
    column: $table.bgTaskId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mediaIndex => $composableBuilder(
    column: $table.mediaIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaSourceId => $composableBuilder(
    column: $table.mediaSourceId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get libraryId => $composableBuilder(
    column: $table.libraryId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get libraryTitle => $composableBuilder(
    column: $table.libraryTitle,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DownloadedMediaTableAnnotationComposer
    extends Composer<_$AppDatabase, $DownloadedMediaTable> {
  $$DownloadedMediaTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get clientScopeId => $composableBuilder(
    column: $table.clientScopeId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ratingKey =>
      $composableBuilder(column: $table.ratingKey, builder: (column) => column);

  GeneratedColumn<String> get globalKey =>
      $composableBuilder(column: $table.globalKey, builder: (column) => column);

  GeneratedColumn<String> get type =>
      $composableBuilder(column: $table.type, builder: (column) => column);

  GeneratedColumn<String> get parentRatingKey => $composableBuilder(
    column: $table.parentRatingKey,
    builder: (column) => column,
  );

  GeneratedColumn<String> get grandparentRatingKey => $composableBuilder(
    column: $table.grandparentRatingKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<int> get progress =>
      $composableBuilder(column: $table.progress, builder: (column) => column);

  GeneratedColumn<int> get totalBytes => $composableBuilder(
    column: $table.totalBytes,
    builder: (column) => column,
  );

  GeneratedColumn<int> get downloadedBytes => $composableBuilder(
    column: $table.downloadedBytes,
    builder: (column) => column,
  );

  GeneratedColumn<String> get videoFilePath => $composableBuilder(
    column: $table.videoFilePath,
    builder: (column) => column,
  );

  GeneratedColumn<String> get additionalPartPaths => $composableBuilder(
    column: $table.additionalPartPaths,
    builder: (column) => column,
  );

  GeneratedColumn<String> get safRootUri => $composableBuilder(
    column: $table.safRootUri,
    builder: (column) => column,
  );

  GeneratedColumn<String> get thumbPath =>
      $composableBuilder(column: $table.thumbPath, builder: (column) => column);

  GeneratedColumn<int> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get errorMessage => $composableBuilder(
    column: $table.errorMessage,
    builder: (column) => column,
  );

  GeneratedColumn<int> get retryCount => $composableBuilder(
    column: $table.retryCount,
    builder: (column) => column,
  );

  GeneratedColumn<String> get bgTaskId =>
      $composableBuilder(column: $table.bgTaskId, builder: (column) => column);

  GeneratedColumn<int> get mediaIndex => $composableBuilder(
    column: $table.mediaIndex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get mediaSourceId => $composableBuilder(
    column: $table.mediaSourceId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get libraryId =>
      $composableBuilder(column: $table.libraryId, builder: (column) => column);

  GeneratedColumn<String> get libraryTitle => $composableBuilder(
    column: $table.libraryTitle,
    builder: (column) => column,
  );
}

class $$DownloadedMediaTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadedMediaTable,
          DownloadedMediaItem,
          $$DownloadedMediaTableFilterComposer,
          $$DownloadedMediaTableOrderingComposer,
          $$DownloadedMediaTableAnnotationComposer,
          $$DownloadedMediaTableCreateCompanionBuilder,
          $$DownloadedMediaTableUpdateCompanionBuilder,
          (
            DownloadedMediaItem,
            BaseReferences<
              _$AppDatabase,
              $DownloadedMediaTable,
              DownloadedMediaItem
            >,
          ),
          DownloadedMediaItem,
          PrefetchHooks Function()
        > {
  $$DownloadedMediaTableTableManager(
    _$AppDatabase db,
    $DownloadedMediaTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadedMediaTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadedMediaTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadedMediaTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> serverId = const Value.absent(),
                Value<String?> clientScopeId = const Value.absent(),
                Value<String> ratingKey = const Value.absent(),
                Value<String> globalKey = const Value.absent(),
                Value<String> type = const Value.absent(),
                Value<String?> parentRatingKey = const Value.absent(),
                Value<String?> grandparentRatingKey = const Value.absent(),
                Value<int> status = const Value.absent(),
                Value<int> progress = const Value.absent(),
                Value<int?> totalBytes = const Value.absent(),
                Value<int> downloadedBytes = const Value.absent(),
                Value<String?> videoFilePath = const Value.absent(),
                Value<String?> additionalPartPaths = const Value.absent(),
                Value<String?> safRootUri = const Value.absent(),
                Value<String?> thumbPath = const Value.absent(),
                Value<int?> downloadedAt = const Value.absent(),
                Value<String?> errorMessage = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                Value<String?> bgTaskId = const Value.absent(),
                Value<int> mediaIndex = const Value.absent(),
                Value<String?> mediaSourceId = const Value.absent(),
                Value<String?> libraryId = const Value.absent(),
                Value<String?> libraryTitle = const Value.absent(),
              }) => DownloadedMediaCompanion(
                id: id,
                serverId: serverId,
                clientScopeId: clientScopeId,
                ratingKey: ratingKey,
                globalKey: globalKey,
                type: type,
                parentRatingKey: parentRatingKey,
                grandparentRatingKey: grandparentRatingKey,
                status: status,
                progress: progress,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes,
                videoFilePath: videoFilePath,
                additionalPartPaths: additionalPartPaths,
                safRootUri: safRootUri,
                thumbPath: thumbPath,
                downloadedAt: downloadedAt,
                errorMessage: errorMessage,
                retryCount: retryCount,
                bgTaskId: bgTaskId,
                mediaIndex: mediaIndex,
                mediaSourceId: mediaSourceId,
                libraryId: libraryId,
                libraryTitle: libraryTitle,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String serverId,
                Value<String?> clientScopeId = const Value.absent(),
                required String ratingKey,
                required String globalKey,
                required String type,
                Value<String?> parentRatingKey = const Value.absent(),
                Value<String?> grandparentRatingKey = const Value.absent(),
                required int status,
                Value<int> progress = const Value.absent(),
                Value<int?> totalBytes = const Value.absent(),
                Value<int> downloadedBytes = const Value.absent(),
                Value<String?> videoFilePath = const Value.absent(),
                Value<String?> additionalPartPaths = const Value.absent(),
                Value<String?> safRootUri = const Value.absent(),
                Value<String?> thumbPath = const Value.absent(),
                Value<int?> downloadedAt = const Value.absent(),
                Value<String?> errorMessage = const Value.absent(),
                Value<int> retryCount = const Value.absent(),
                Value<String?> bgTaskId = const Value.absent(),
                Value<int> mediaIndex = const Value.absent(),
                Value<String?> mediaSourceId = const Value.absent(),
                Value<String?> libraryId = const Value.absent(),
                Value<String?> libraryTitle = const Value.absent(),
              }) => DownloadedMediaCompanion.insert(
                id: id,
                serverId: serverId,
                clientScopeId: clientScopeId,
                ratingKey: ratingKey,
                globalKey: globalKey,
                type: type,
                parentRatingKey: parentRatingKey,
                grandparentRatingKey: grandparentRatingKey,
                status: status,
                progress: progress,
                totalBytes: totalBytes,
                downloadedBytes: downloadedBytes,
                videoFilePath: videoFilePath,
                additionalPartPaths: additionalPartPaths,
                safRootUri: safRootUri,
                thumbPath: thumbPath,
                downloadedAt: downloadedAt,
                errorMessage: errorMessage,
                retryCount: retryCount,
                bgTaskId: bgTaskId,
                mediaIndex: mediaIndex,
                mediaSourceId: mediaSourceId,
                libraryId: libraryId,
                libraryTitle: libraryTitle,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadedMediaTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadedMediaTable,
      DownloadedMediaItem,
      $$DownloadedMediaTableFilterComposer,
      $$DownloadedMediaTableOrderingComposer,
      $$DownloadedMediaTableAnnotationComposer,
      $$DownloadedMediaTableCreateCompanionBuilder,
      $$DownloadedMediaTableUpdateCompanionBuilder,
      (
        DownloadedMediaItem,
        BaseReferences<
          _$AppDatabase,
          $DownloadedMediaTable,
          DownloadedMediaItem
        >,
      ),
      DownloadedMediaItem,
      PrefetchHooks Function()
    >;
typedef $$DownloadOwnersTableCreateCompanionBuilder =
    DownloadOwnersCompanion Function({
      required String profileId,
      required String globalKey,
      Value<String?> backend,
      Value<String?> clientScopeId,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$DownloadOwnersTableUpdateCompanionBuilder =
    DownloadOwnersCompanion Function({
      Value<String> profileId,
      Value<String> globalKey,
      Value<String?> backend,
      Value<String?> clientScopeId,
      Value<int> createdAt,
      Value<int> rowid,
    });

class $$DownloadOwnersTableFilterComposer
    extends Composer<_$AppDatabase, $DownloadOwnersTable> {
  $$DownloadOwnersTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get globalKey => $composableBuilder(
    column: $table.globalKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get backend => $composableBuilder(
    column: $table.backend,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get clientScopeId => $composableBuilder(
    column: $table.clientScopeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DownloadOwnersTableOrderingComposer
    extends Composer<_$AppDatabase, $DownloadOwnersTable> {
  $$DownloadOwnersTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get globalKey => $composableBuilder(
    column: $table.globalKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get backend => $composableBuilder(
    column: $table.backend,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get clientScopeId => $composableBuilder(
    column: $table.clientScopeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DownloadOwnersTableAnnotationComposer
    extends Composer<_$AppDatabase, $DownloadOwnersTable> {
  $$DownloadOwnersTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get globalKey =>
      $composableBuilder(column: $table.globalKey, builder: (column) => column);

  GeneratedColumn<String> get backend =>
      $composableBuilder(column: $table.backend, builder: (column) => column);

  GeneratedColumn<String> get clientScopeId => $composableBuilder(
    column: $table.clientScopeId,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);
}

class $$DownloadOwnersTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadOwnersTable,
          DownloadOwnerItem,
          $$DownloadOwnersTableFilterComposer,
          $$DownloadOwnersTableOrderingComposer,
          $$DownloadOwnersTableAnnotationComposer,
          $$DownloadOwnersTableCreateCompanionBuilder,
          $$DownloadOwnersTableUpdateCompanionBuilder,
          (
            DownloadOwnerItem,
            BaseReferences<
              _$AppDatabase,
              $DownloadOwnersTable,
              DownloadOwnerItem
            >,
          ),
          DownloadOwnerItem,
          PrefetchHooks Function()
        > {
  $$DownloadOwnersTableTableManager(
    _$AppDatabase db,
    $DownloadOwnersTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadOwnersTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadOwnersTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadOwnersTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<String> globalKey = const Value.absent(),
                Value<String?> backend = const Value.absent(),
                Value<String?> clientScopeId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DownloadOwnersCompanion(
                profileId: profileId,
                globalKey: globalKey,
                backend: backend,
                clientScopeId: clientScopeId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required String globalKey,
                Value<String?> backend = const Value.absent(),
                Value<String?> clientScopeId = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => DownloadOwnersCompanion.insert(
                profileId: profileId,
                globalKey: globalKey,
                backend: backend,
                clientScopeId: clientScopeId,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadOwnersTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadOwnersTable,
      DownloadOwnerItem,
      $$DownloadOwnersTableFilterComposer,
      $$DownloadOwnersTableOrderingComposer,
      $$DownloadOwnersTableAnnotationComposer,
      $$DownloadOwnersTableCreateCompanionBuilder,
      $$DownloadOwnersTableUpdateCompanionBuilder,
      (
        DownloadOwnerItem,
        BaseReferences<_$AppDatabase, $DownloadOwnersTable, DownloadOwnerItem>,
      ),
      DownloadOwnerItem,
      PrefetchHooks Function()
    >;
typedef $$DownloadQueueTableCreateCompanionBuilder =
    DownloadQueueCompanion Function({
      Value<int> id,
      required String mediaGlobalKey,
      Value<int> priority,
      required int addedAt,
      Value<bool> downloadSubtitles,
      Value<bool> downloadArtwork,
    });
typedef $$DownloadQueueTableUpdateCompanionBuilder =
    DownloadQueueCompanion Function({
      Value<int> id,
      Value<String> mediaGlobalKey,
      Value<int> priority,
      Value<int> addedAt,
      Value<bool> downloadSubtitles,
      Value<bool> downloadArtwork,
    });

class $$DownloadQueueTableFilterComposer
    extends Composer<_$AppDatabase, $DownloadQueueTable> {
  $$DownloadQueueTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get mediaGlobalKey => $composableBuilder(
    column: $table.mediaGlobalKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get downloadSubtitles => $composableBuilder(
    column: $table.downloadSubtitles,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get downloadArtwork => $composableBuilder(
    column: $table.downloadArtwork,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DownloadQueueTableOrderingComposer
    extends Composer<_$AppDatabase, $DownloadQueueTable> {
  $$DownloadQueueTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get mediaGlobalKey => $composableBuilder(
    column: $table.mediaGlobalKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get priority => $composableBuilder(
    column: $table.priority,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get downloadSubtitles => $composableBuilder(
    column: $table.downloadSubtitles,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get downloadArtwork => $composableBuilder(
    column: $table.downloadArtwork,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DownloadQueueTableAnnotationComposer
    extends Composer<_$AppDatabase, $DownloadQueueTable> {
  $$DownloadQueueTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get mediaGlobalKey => $composableBuilder(
    column: $table.mediaGlobalKey,
    builder: (column) => column,
  );

  GeneratedColumn<int> get priority =>
      $composableBuilder(column: $table.priority, builder: (column) => column);

  GeneratedColumn<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<bool> get downloadSubtitles => $composableBuilder(
    column: $table.downloadSubtitles,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get downloadArtwork => $composableBuilder(
    column: $table.downloadArtwork,
    builder: (column) => column,
  );
}

class $$DownloadQueueTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadQueueTable,
          DownloadQueueItem,
          $$DownloadQueueTableFilterComposer,
          $$DownloadQueueTableOrderingComposer,
          $$DownloadQueueTableAnnotationComposer,
          $$DownloadQueueTableCreateCompanionBuilder,
          $$DownloadQueueTableUpdateCompanionBuilder,
          (
            DownloadQueueItem,
            BaseReferences<
              _$AppDatabase,
              $DownloadQueueTable,
              DownloadQueueItem
            >,
          ),
          DownloadQueueItem,
          PrefetchHooks Function()
        > {
  $$DownloadQueueTableTableManager(_$AppDatabase db, $DownloadQueueTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadQueueTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadQueueTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$DownloadQueueTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> mediaGlobalKey = const Value.absent(),
                Value<int> priority = const Value.absent(),
                Value<int> addedAt = const Value.absent(),
                Value<bool> downloadSubtitles = const Value.absent(),
                Value<bool> downloadArtwork = const Value.absent(),
              }) => DownloadQueueCompanion(
                id: id,
                mediaGlobalKey: mediaGlobalKey,
                priority: priority,
                addedAt: addedAt,
                downloadSubtitles: downloadSubtitles,
                downloadArtwork: downloadArtwork,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String mediaGlobalKey,
                Value<int> priority = const Value.absent(),
                required int addedAt,
                Value<bool> downloadSubtitles = const Value.absent(),
                Value<bool> downloadArtwork = const Value.absent(),
              }) => DownloadQueueCompanion.insert(
                id: id,
                mediaGlobalKey: mediaGlobalKey,
                priority: priority,
                addedAt: addedAt,
                downloadSubtitles: downloadSubtitles,
                downloadArtwork: downloadArtwork,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadQueueTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadQueueTable,
      DownloadQueueItem,
      $$DownloadQueueTableFilterComposer,
      $$DownloadQueueTableOrderingComposer,
      $$DownloadQueueTableAnnotationComposer,
      $$DownloadQueueTableCreateCompanionBuilder,
      $$DownloadQueueTableUpdateCompanionBuilder,
      (
        DownloadQueueItem,
        BaseReferences<_$AppDatabase, $DownloadQueueTable, DownloadQueueItem>,
      ),
      DownloadQueueItem,
      PrefetchHooks Function()
    >;
typedef $$ApiCacheTableCreateCompanionBuilder =
    ApiCacheCompanion Function({
      required String cacheKey,
      required String data,
      Value<DateTime> cachedAt,
      Value<bool> pinned,
      Value<int> rowid,
    });
typedef $$ApiCacheTableUpdateCompanionBuilder =
    ApiCacheCompanion Function({
      Value<String> cacheKey,
      Value<String> data,
      Value<DateTime> cachedAt,
      Value<bool> pinned,
      Value<int> rowid,
    });

class $$ApiCacheTableFilterComposer
    extends Composer<_$AppDatabase, $ApiCacheTable> {
  $$ApiCacheTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get cacheKey => $composableBuilder(
    column: $table.cacheKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ApiCacheTableOrderingComposer
    extends Composer<_$AppDatabase, $ApiCacheTable> {
  $$ApiCacheTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get cacheKey => $composableBuilder(
    column: $table.cacheKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get data => $composableBuilder(
    column: $table.data,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get cachedAt => $composableBuilder(
    column: $table.cachedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get pinned => $composableBuilder(
    column: $table.pinned,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ApiCacheTableAnnotationComposer
    extends Composer<_$AppDatabase, $ApiCacheTable> {
  $$ApiCacheTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get cacheKey =>
      $composableBuilder(column: $table.cacheKey, builder: (column) => column);

  GeneratedColumn<String> get data =>
      $composableBuilder(column: $table.data, builder: (column) => column);

  GeneratedColumn<DateTime> get cachedAt =>
      $composableBuilder(column: $table.cachedAt, builder: (column) => column);

  GeneratedColumn<bool> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => column);
}

class $$ApiCacheTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ApiCacheTable,
          ApiCacheData,
          $$ApiCacheTableFilterComposer,
          $$ApiCacheTableOrderingComposer,
          $$ApiCacheTableAnnotationComposer,
          $$ApiCacheTableCreateCompanionBuilder,
          $$ApiCacheTableUpdateCompanionBuilder,
          (
            ApiCacheData,
            BaseReferences<_$AppDatabase, $ApiCacheTable, ApiCacheData>,
          ),
          ApiCacheData,
          PrefetchHooks Function()
        > {
  $$ApiCacheTableTableManager(_$AppDatabase db, $ApiCacheTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ApiCacheTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ApiCacheTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ApiCacheTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> cacheKey = const Value.absent(),
                Value<String> data = const Value.absent(),
                Value<DateTime> cachedAt = const Value.absent(),
                Value<bool> pinned = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ApiCacheCompanion(
                cacheKey: cacheKey,
                data: data,
                cachedAt: cachedAt,
                pinned: pinned,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String cacheKey,
                required String data,
                Value<DateTime> cachedAt = const Value.absent(),
                Value<bool> pinned = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ApiCacheCompanion.insert(
                cacheKey: cacheKey,
                data: data,
                cachedAt: cachedAt,
                pinned: pinned,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ApiCacheTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ApiCacheTable,
      ApiCacheData,
      $$ApiCacheTableFilterComposer,
      $$ApiCacheTableOrderingComposer,
      $$ApiCacheTableAnnotationComposer,
      $$ApiCacheTableCreateCompanionBuilder,
      $$ApiCacheTableUpdateCompanionBuilder,
      (
        ApiCacheData,
        BaseReferences<_$AppDatabase, $ApiCacheTable, ApiCacheData>,
      ),
      ApiCacheData,
      PrefetchHooks Function()
    >;
typedef $$OfflineWatchProgressTableCreateCompanionBuilder =
    OfflineWatchProgressCompanion Function({
      Value<int> id,
      Value<String?> profileId,
      required String serverId,
      Value<String?> clientScopeId,
      required String ratingKey,
      required String globalKey,
      required String actionType,
      Value<int?> viewOffset,
      Value<int?> duration,
      Value<bool> shouldMarkWatched,
      required int createdAt,
      required int updatedAt,
      Value<int> syncAttempts,
      Value<String?> lastError,
    });
typedef $$OfflineWatchProgressTableUpdateCompanionBuilder =
    OfflineWatchProgressCompanion Function({
      Value<int> id,
      Value<String?> profileId,
      Value<String> serverId,
      Value<String?> clientScopeId,
      Value<String> ratingKey,
      Value<String> globalKey,
      Value<String> actionType,
      Value<int?> viewOffset,
      Value<int?> duration,
      Value<bool> shouldMarkWatched,
      Value<int> createdAt,
      Value<int> updatedAt,
      Value<int> syncAttempts,
      Value<String?> lastError,
    });

class $$OfflineWatchProgressTableFilterComposer
    extends Composer<_$AppDatabase, $OfflineWatchProgressTable> {
  $$OfflineWatchProgressTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get clientScopeId => $composableBuilder(
    column: $table.clientScopeId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ratingKey => $composableBuilder(
    column: $table.ratingKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get globalKey => $composableBuilder(
    column: $table.globalKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get viewOffset => $composableBuilder(
    column: $table.viewOffset,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get shouldMarkWatched => $composableBuilder(
    column: $table.shouldMarkWatched,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncAttempts => $composableBuilder(
    column: $table.syncAttempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );
}

class $$OfflineWatchProgressTableOrderingComposer
    extends Composer<_$AppDatabase, $OfflineWatchProgressTable> {
  $$OfflineWatchProgressTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get clientScopeId => $composableBuilder(
    column: $table.clientScopeId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ratingKey => $composableBuilder(
    column: $table.ratingKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get globalKey => $composableBuilder(
    column: $table.globalKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get viewOffset => $composableBuilder(
    column: $table.viewOffset,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get duration => $composableBuilder(
    column: $table.duration,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get shouldMarkWatched => $composableBuilder(
    column: $table.shouldMarkWatched,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncAttempts => $composableBuilder(
    column: $table.syncAttempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$OfflineWatchProgressTableAnnotationComposer
    extends Composer<_$AppDatabase, $OfflineWatchProgressTable> {
  $$OfflineWatchProgressTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get clientScopeId => $composableBuilder(
    column: $table.clientScopeId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get ratingKey =>
      $composableBuilder(column: $table.ratingKey, builder: (column) => column);

  GeneratedColumn<String> get globalKey =>
      $composableBuilder(column: $table.globalKey, builder: (column) => column);

  GeneratedColumn<String> get actionType => $composableBuilder(
    column: $table.actionType,
    builder: (column) => column,
  );

  GeneratedColumn<int> get viewOffset => $composableBuilder(
    column: $table.viewOffset,
    builder: (column) => column,
  );

  GeneratedColumn<int> get duration =>
      $composableBuilder(column: $table.duration, builder: (column) => column);

  GeneratedColumn<bool> get shouldMarkWatched => $composableBuilder(
    column: $table.shouldMarkWatched,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get syncAttempts => $composableBuilder(
    column: $table.syncAttempts,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);
}

class $$OfflineWatchProgressTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $OfflineWatchProgressTable,
          OfflineWatchProgressItem,
          $$OfflineWatchProgressTableFilterComposer,
          $$OfflineWatchProgressTableOrderingComposer,
          $$OfflineWatchProgressTableAnnotationComposer,
          $$OfflineWatchProgressTableCreateCompanionBuilder,
          $$OfflineWatchProgressTableUpdateCompanionBuilder,
          (
            OfflineWatchProgressItem,
            BaseReferences<
              _$AppDatabase,
              $OfflineWatchProgressTable,
              OfflineWatchProgressItem
            >,
          ),
          OfflineWatchProgressItem,
          PrefetchHooks Function()
        > {
  $$OfflineWatchProgressTableTableManager(
    _$AppDatabase db,
    $OfflineWatchProgressTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$OfflineWatchProgressTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$OfflineWatchProgressTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$OfflineWatchProgressTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> profileId = const Value.absent(),
                Value<String> serverId = const Value.absent(),
                Value<String?> clientScopeId = const Value.absent(),
                Value<String> ratingKey = const Value.absent(),
                Value<String> globalKey = const Value.absent(),
                Value<String> actionType = const Value.absent(),
                Value<int?> viewOffset = const Value.absent(),
                Value<int?> duration = const Value.absent(),
                Value<bool> shouldMarkWatched = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> syncAttempts = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
              }) => OfflineWatchProgressCompanion(
                id: id,
                profileId: profileId,
                serverId: serverId,
                clientScopeId: clientScopeId,
                ratingKey: ratingKey,
                globalKey: globalKey,
                actionType: actionType,
                viewOffset: viewOffset,
                duration: duration,
                shouldMarkWatched: shouldMarkWatched,
                createdAt: createdAt,
                updatedAt: updatedAt,
                syncAttempts: syncAttempts,
                lastError: lastError,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String?> profileId = const Value.absent(),
                required String serverId,
                Value<String?> clientScopeId = const Value.absent(),
                required String ratingKey,
                required String globalKey,
                required String actionType,
                Value<int?> viewOffset = const Value.absent(),
                Value<int?> duration = const Value.absent(),
                Value<bool> shouldMarkWatched = const Value.absent(),
                required int createdAt,
                required int updatedAt,
                Value<int> syncAttempts = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
              }) => OfflineWatchProgressCompanion.insert(
                id: id,
                profileId: profileId,
                serverId: serverId,
                clientScopeId: clientScopeId,
                ratingKey: ratingKey,
                globalKey: globalKey,
                actionType: actionType,
                viewOffset: viewOffset,
                duration: duration,
                shouldMarkWatched: shouldMarkWatched,
                createdAt: createdAt,
                updatedAt: updatedAt,
                syncAttempts: syncAttempts,
                lastError: lastError,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$OfflineWatchProgressTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $OfflineWatchProgressTable,
      OfflineWatchProgressItem,
      $$OfflineWatchProgressTableFilterComposer,
      $$OfflineWatchProgressTableOrderingComposer,
      $$OfflineWatchProgressTableAnnotationComposer,
      $$OfflineWatchProgressTableCreateCompanionBuilder,
      $$OfflineWatchProgressTableUpdateCompanionBuilder,
      (
        OfflineWatchProgressItem,
        BaseReferences<
          _$AppDatabase,
          $OfflineWatchProgressTable,
          OfflineWatchProgressItem
        >,
      ),
      OfflineWatchProgressItem,
      PrefetchHooks Function()
    >;
typedef $$SyncRulesTableCreateCompanionBuilder =
    SyncRulesCompanion Function({
      Value<int> id,
      Value<String> profileId,
      required String serverId,
      required String ratingKey,
      required String globalKey,
      required String targetType,
      required int episodeCount,
      Value<bool> enabled,
      required int createdAt,
      Value<int?> lastExecutedAt,
      Value<int> mediaIndex,
      Value<String> downloadFilter,
      Value<bool> includeSpecials,
      Value<bool> downloadLinksInitialized,
    });
typedef $$SyncRulesTableUpdateCompanionBuilder =
    SyncRulesCompanion Function({
      Value<int> id,
      Value<String> profileId,
      Value<String> serverId,
      Value<String> ratingKey,
      Value<String> globalKey,
      Value<String> targetType,
      Value<int> episodeCount,
      Value<bool> enabled,
      Value<int> createdAt,
      Value<int?> lastExecutedAt,
      Value<int> mediaIndex,
      Value<String> downloadFilter,
      Value<bool> includeSpecials,
      Value<bool> downloadLinksInitialized,
    });

final class $$SyncRulesTableReferences
    extends BaseReferences<_$AppDatabase, $SyncRulesTable, SyncRuleItem> {
  $$SyncRulesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<
    $SyncRuleDownloadsTable,
    List<SyncRuleDownloadItem>
  >
  _syncRuleDownloadsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.syncRuleDownloads,
        aliasName: 'sync_rules__id__sync_rule_downloads__sync_rule_id',
      );

  $$SyncRuleDownloadsTableProcessedTableManager get syncRuleDownloadsRefs {
    final manager = $$SyncRuleDownloadsTableTableManager(
      $_db,
      $_db.syncRuleDownloads,
    ).filter((f) => f.syncRuleId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _syncRuleDownloadsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$SyncRulesTableFilterComposer
    extends Composer<_$AppDatabase, $SyncRulesTable> {
  $$SyncRulesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get ratingKey => $composableBuilder(
    column: $table.ratingKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get globalKey => $composableBuilder(
    column: $table.globalKey,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get episodeCount => $composableBuilder(
    column: $table.episodeCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastExecutedAt => $composableBuilder(
    column: $table.lastExecutedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get mediaIndex => $composableBuilder(
    column: $table.mediaIndex,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get downloadFilter => $composableBuilder(
    column: $table.downloadFilter,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get includeSpecials => $composableBuilder(
    column: $table.includeSpecials,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get downloadLinksInitialized => $composableBuilder(
    column: $table.downloadLinksInitialized,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> syncRuleDownloadsRefs(
    Expression<bool> Function($$SyncRuleDownloadsTableFilterComposer f) f,
  ) {
    final $$SyncRuleDownloadsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.syncRuleDownloads,
      getReferencedColumn: (t) => t.syncRuleId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncRuleDownloadsTableFilterComposer(
            $db: $db,
            $table: $db.syncRuleDownloads,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$SyncRulesTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncRulesTable> {
  $$SyncRulesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get ratingKey => $composableBuilder(
    column: $table.ratingKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get globalKey => $composableBuilder(
    column: $table.globalKey,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get episodeCount => $composableBuilder(
    column: $table.episodeCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get enabled => $composableBuilder(
    column: $table.enabled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastExecutedAt => $composableBuilder(
    column: $table.lastExecutedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get mediaIndex => $composableBuilder(
    column: $table.mediaIndex,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get downloadFilter => $composableBuilder(
    column: $table.downloadFilter,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get includeSpecials => $composableBuilder(
    column: $table.includeSpecials,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get downloadLinksInitialized => $composableBuilder(
    column: $table.downloadLinksInitialized,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$SyncRulesTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncRulesTable> {
  $$SyncRulesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get ratingKey =>
      $composableBuilder(column: $table.ratingKey, builder: (column) => column);

  GeneratedColumn<String> get globalKey =>
      $composableBuilder(column: $table.globalKey, builder: (column) => column);

  GeneratedColumn<String> get targetType => $composableBuilder(
    column: $table.targetType,
    builder: (column) => column,
  );

  GeneratedColumn<int> get episodeCount => $composableBuilder(
    column: $table.episodeCount,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get enabled =>
      $composableBuilder(column: $table.enabled, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get lastExecutedAt => $composableBuilder(
    column: $table.lastExecutedAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get mediaIndex => $composableBuilder(
    column: $table.mediaIndex,
    builder: (column) => column,
  );

  GeneratedColumn<String> get downloadFilter => $composableBuilder(
    column: $table.downloadFilter,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get includeSpecials => $composableBuilder(
    column: $table.includeSpecials,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get downloadLinksInitialized => $composableBuilder(
    column: $table.downloadLinksInitialized,
    builder: (column) => column,
  );

  Expression<T> syncRuleDownloadsRefs<T extends Object>(
    Expression<T> Function($$SyncRuleDownloadsTableAnnotationComposer a) f,
  ) {
    final $$SyncRuleDownloadsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.syncRuleDownloads,
          getReferencedColumn: (t) => t.syncRuleId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$SyncRuleDownloadsTableAnnotationComposer(
                $db: $db,
                $table: $db.syncRuleDownloads,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$SyncRulesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncRulesTable,
          SyncRuleItem,
          $$SyncRulesTableFilterComposer,
          $$SyncRulesTableOrderingComposer,
          $$SyncRulesTableAnnotationComposer,
          $$SyncRulesTableCreateCompanionBuilder,
          $$SyncRulesTableUpdateCompanionBuilder,
          (SyncRuleItem, $$SyncRulesTableReferences),
          SyncRuleItem,
          PrefetchHooks Function({bool syncRuleDownloadsRefs})
        > {
  $$SyncRulesTableTableManager(_$AppDatabase db, $SyncRulesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncRulesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncRulesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncRulesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> profileId = const Value.absent(),
                Value<String> serverId = const Value.absent(),
                Value<String> ratingKey = const Value.absent(),
                Value<String> globalKey = const Value.absent(),
                Value<String> targetType = const Value.absent(),
                Value<int> episodeCount = const Value.absent(),
                Value<bool> enabled = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int?> lastExecutedAt = const Value.absent(),
                Value<int> mediaIndex = const Value.absent(),
                Value<String> downloadFilter = const Value.absent(),
                Value<bool> includeSpecials = const Value.absent(),
                Value<bool> downloadLinksInitialized = const Value.absent(),
              }) => SyncRulesCompanion(
                id: id,
                profileId: profileId,
                serverId: serverId,
                ratingKey: ratingKey,
                globalKey: globalKey,
                targetType: targetType,
                episodeCount: episodeCount,
                enabled: enabled,
                createdAt: createdAt,
                lastExecutedAt: lastExecutedAt,
                mediaIndex: mediaIndex,
                downloadFilter: downloadFilter,
                includeSpecials: includeSpecials,
                downloadLinksInitialized: downloadLinksInitialized,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> profileId = const Value.absent(),
                required String serverId,
                required String ratingKey,
                required String globalKey,
                required String targetType,
                required int episodeCount,
                Value<bool> enabled = const Value.absent(),
                required int createdAt,
                Value<int?> lastExecutedAt = const Value.absent(),
                Value<int> mediaIndex = const Value.absent(),
                Value<String> downloadFilter = const Value.absent(),
                Value<bool> includeSpecials = const Value.absent(),
                Value<bool> downloadLinksInitialized = const Value.absent(),
              }) => SyncRulesCompanion.insert(
                id: id,
                profileId: profileId,
                serverId: serverId,
                ratingKey: ratingKey,
                globalKey: globalKey,
                targetType: targetType,
                episodeCount: episodeCount,
                enabled: enabled,
                createdAt: createdAt,
                lastExecutedAt: lastExecutedAt,
                mediaIndex: mediaIndex,
                downloadFilter: downloadFilter,
                includeSpecials: includeSpecials,
                downloadLinksInitialized: downloadLinksInitialized,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SyncRulesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({syncRuleDownloadsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (syncRuleDownloadsRefs) db.syncRuleDownloads,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (syncRuleDownloadsRefs)
                    await $_getPrefetchedData<
                      SyncRuleItem,
                      $SyncRulesTable,
                      SyncRuleDownloadItem
                    >(
                      currentTable: table,
                      referencedTable: $$SyncRulesTableReferences
                          ._syncRuleDownloadsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$SyncRulesTableReferences(
                            db,
                            table,
                            p0,
                          ).syncRuleDownloadsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.syncRuleId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$SyncRulesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncRulesTable,
      SyncRuleItem,
      $$SyncRulesTableFilterComposer,
      $$SyncRulesTableOrderingComposer,
      $$SyncRulesTableAnnotationComposer,
      $$SyncRulesTableCreateCompanionBuilder,
      $$SyncRulesTableUpdateCompanionBuilder,
      (SyncRuleItem, $$SyncRulesTableReferences),
      SyncRuleItem,
      PrefetchHooks Function({bool syncRuleDownloadsRefs})
    >;
typedef $$SyncRuleDownloadsTableCreateCompanionBuilder =
    SyncRuleDownloadsCompanion Function({
      required int syncRuleId,
      required String profileId,
      required String downloadGlobalKey,
      Value<int> rowid,
    });
typedef $$SyncRuleDownloadsTableUpdateCompanionBuilder =
    SyncRuleDownloadsCompanion Function({
      Value<int> syncRuleId,
      Value<String> profileId,
      Value<String> downloadGlobalKey,
      Value<int> rowid,
    });

final class $$SyncRuleDownloadsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $SyncRuleDownloadsTable,
          SyncRuleDownloadItem
        > {
  $$SyncRuleDownloadsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $SyncRulesTable _syncRuleIdTable(_$AppDatabase db) => db.syncRules
      .createAlias('sync_rule_downloads__sync_rule_id__sync_rules__id');

  $$SyncRulesTableProcessedTableManager get syncRuleId {
    final $_column = $_itemColumn<int>('sync_rule_id')!;

    final manager = $$SyncRulesTableTableManager(
      $_db,
      $_db.syncRules,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_syncRuleIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$SyncRuleDownloadsTableFilterComposer
    extends Composer<_$AppDatabase, $SyncRuleDownloadsTable> {
  $$SyncRuleDownloadsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get downloadGlobalKey => $composableBuilder(
    column: $table.downloadGlobalKey,
    builder: (column) => ColumnFilters(column),
  );

  $$SyncRulesTableFilterComposer get syncRuleId {
    final $$SyncRulesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.syncRuleId,
      referencedTable: $db.syncRules,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncRulesTableFilterComposer(
            $db: $db,
            $table: $db.syncRules,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncRuleDownloadsTableOrderingComposer
    extends Composer<_$AppDatabase, $SyncRuleDownloadsTable> {
  $$SyncRuleDownloadsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get downloadGlobalKey => $composableBuilder(
    column: $table.downloadGlobalKey,
    builder: (column) => ColumnOrderings(column),
  );

  $$SyncRulesTableOrderingComposer get syncRuleId {
    final $$SyncRulesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.syncRuleId,
      referencedTable: $db.syncRules,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncRulesTableOrderingComposer(
            $db: $db,
            $table: $db.syncRules,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncRuleDownloadsTableAnnotationComposer
    extends Composer<_$AppDatabase, $SyncRuleDownloadsTable> {
  $$SyncRuleDownloadsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get downloadGlobalKey => $composableBuilder(
    column: $table.downloadGlobalKey,
    builder: (column) => column,
  );

  $$SyncRulesTableAnnotationComposer get syncRuleId {
    final $$SyncRulesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.syncRuleId,
      referencedTable: $db.syncRules,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$SyncRulesTableAnnotationComposer(
            $db: $db,
            $table: $db.syncRules,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$SyncRuleDownloadsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $SyncRuleDownloadsTable,
          SyncRuleDownloadItem,
          $$SyncRuleDownloadsTableFilterComposer,
          $$SyncRuleDownloadsTableOrderingComposer,
          $$SyncRuleDownloadsTableAnnotationComposer,
          $$SyncRuleDownloadsTableCreateCompanionBuilder,
          $$SyncRuleDownloadsTableUpdateCompanionBuilder,
          (SyncRuleDownloadItem, $$SyncRuleDownloadsTableReferences),
          SyncRuleDownloadItem,
          PrefetchHooks Function({bool syncRuleId})
        > {
  $$SyncRuleDownloadsTableTableManager(
    _$AppDatabase db,
    $SyncRuleDownloadsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$SyncRuleDownloadsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$SyncRuleDownloadsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$SyncRuleDownloadsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> syncRuleId = const Value.absent(),
                Value<String> profileId = const Value.absent(),
                Value<String> downloadGlobalKey = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => SyncRuleDownloadsCompanion(
                syncRuleId: syncRuleId,
                profileId: profileId,
                downloadGlobalKey: downloadGlobalKey,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int syncRuleId,
                required String profileId,
                required String downloadGlobalKey,
                Value<int> rowid = const Value.absent(),
              }) => SyncRuleDownloadsCompanion.insert(
                syncRuleId: syncRuleId,
                profileId: profileId,
                downloadGlobalKey: downloadGlobalKey,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$SyncRuleDownloadsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({syncRuleId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (syncRuleId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.syncRuleId,
                                referencedTable:
                                    $$SyncRuleDownloadsTableReferences
                                        ._syncRuleIdTable(db),
                                referencedColumn:
                                    $$SyncRuleDownloadsTableReferences
                                        ._syncRuleIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$SyncRuleDownloadsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $SyncRuleDownloadsTable,
      SyncRuleDownloadItem,
      $$SyncRuleDownloadsTableFilterComposer,
      $$SyncRuleDownloadsTableOrderingComposer,
      $$SyncRuleDownloadsTableAnnotationComposer,
      $$SyncRuleDownloadsTableCreateCompanionBuilder,
      $$SyncRuleDownloadsTableUpdateCompanionBuilder,
      (SyncRuleDownloadItem, $$SyncRuleDownloadsTableReferences),
      SyncRuleDownloadItem,
      PrefetchHooks Function({bool syncRuleId})
    >;
typedef $$DownloadCollectionsTableCreateCompanionBuilder =
    DownloadCollectionsCompanion Function({
      required String profileId,
      required String serverId,
      required String collectionId,
      required String memberIds,
      Value<int> rowid,
    });
typedef $$DownloadCollectionsTableUpdateCompanionBuilder =
    DownloadCollectionsCompanion Function({
      Value<String> profileId,
      Value<String> serverId,
      Value<String> collectionId,
      Value<String> memberIds,
      Value<int> rowid,
    });

class $$DownloadCollectionsTableFilterComposer
    extends Composer<_$AppDatabase, $DownloadCollectionsTable> {
  $$DownloadCollectionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get collectionId => $composableBuilder(
    column: $table.collectionId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get memberIds => $composableBuilder(
    column: $table.memberIds,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DownloadCollectionsTableOrderingComposer
    extends Composer<_$AppDatabase, $DownloadCollectionsTable> {
  $$DownloadCollectionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get collectionId => $composableBuilder(
    column: $table.collectionId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get memberIds => $composableBuilder(
    column: $table.memberIds,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DownloadCollectionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DownloadCollectionsTable> {
  $$DownloadCollectionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<String> get collectionId => $composableBuilder(
    column: $table.collectionId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get memberIds =>
      $composableBuilder(column: $table.memberIds, builder: (column) => column);
}

class $$DownloadCollectionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadCollectionsTable,
          DownloadCollectionItem,
          $$DownloadCollectionsTableFilterComposer,
          $$DownloadCollectionsTableOrderingComposer,
          $$DownloadCollectionsTableAnnotationComposer,
          $$DownloadCollectionsTableCreateCompanionBuilder,
          $$DownloadCollectionsTableUpdateCompanionBuilder,
          (
            DownloadCollectionItem,
            BaseReferences<
              _$AppDatabase,
              $DownloadCollectionsTable,
              DownloadCollectionItem
            >,
          ),
          DownloadCollectionItem,
          PrefetchHooks Function()
        > {
  $$DownloadCollectionsTableTableManager(
    _$AppDatabase db,
    $DownloadCollectionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadCollectionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$DownloadCollectionsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$DownloadCollectionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<String> serverId = const Value.absent(),
                Value<String> collectionId = const Value.absent(),
                Value<String> memberIds = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DownloadCollectionsCompanion(
                profileId: profileId,
                serverId: serverId,
                collectionId: collectionId,
                memberIds: memberIds,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required String serverId,
                required String collectionId,
                required String memberIds,
                Value<int> rowid = const Value.absent(),
              }) => DownloadCollectionsCompanion.insert(
                profileId: profileId,
                serverId: serverId,
                collectionId: collectionId,
                memberIds: memberIds,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadCollectionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadCollectionsTable,
      DownloadCollectionItem,
      $$DownloadCollectionsTableFilterComposer,
      $$DownloadCollectionsTableOrderingComposer,
      $$DownloadCollectionsTableAnnotationComposer,
      $$DownloadCollectionsTableCreateCompanionBuilder,
      $$DownloadCollectionsTableUpdateCompanionBuilder,
      (
        DownloadCollectionItem,
        BaseReferences<
          _$AppDatabase,
          $DownloadCollectionsTable,
          DownloadCollectionItem
        >,
      ),
      DownloadCollectionItem,
      PrefetchHooks Function()
    >;
typedef $$DownloadCollectionSyncsTableCreateCompanionBuilder =
    DownloadCollectionSyncsCompanion Function({
      required String profileId,
      required String serverId,
      required int syncedAt,
      required String checkedIds,
      Value<int> rowid,
    });
typedef $$DownloadCollectionSyncsTableUpdateCompanionBuilder =
    DownloadCollectionSyncsCompanion Function({
      Value<String> profileId,
      Value<String> serverId,
      Value<int> syncedAt,
      Value<String> checkedIds,
      Value<int> rowid,
    });

class $$DownloadCollectionSyncsTableFilterComposer
    extends Composer<_$AppDatabase, $DownloadCollectionSyncsTable> {
  $$DownloadCollectionSyncsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get checkedIds => $composableBuilder(
    column: $table.checkedIds,
    builder: (column) => ColumnFilters(column),
  );
}

class $$DownloadCollectionSyncsTableOrderingComposer
    extends Composer<_$AppDatabase, $DownloadCollectionSyncsTable> {
  $$DownloadCollectionSyncsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverId => $composableBuilder(
    column: $table.serverId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get syncedAt => $composableBuilder(
    column: $table.syncedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get checkedIds => $composableBuilder(
    column: $table.checkedIds,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$DownloadCollectionSyncsTableAnnotationComposer
    extends Composer<_$AppDatabase, $DownloadCollectionSyncsTable> {
  $$DownloadCollectionSyncsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get serverId =>
      $composableBuilder(column: $table.serverId, builder: (column) => column);

  GeneratedColumn<int> get syncedAt =>
      $composableBuilder(column: $table.syncedAt, builder: (column) => column);

  GeneratedColumn<String> get checkedIds => $composableBuilder(
    column: $table.checkedIds,
    builder: (column) => column,
  );
}

class $$DownloadCollectionSyncsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $DownloadCollectionSyncsTable,
          DownloadCollectionSyncItem,
          $$DownloadCollectionSyncsTableFilterComposer,
          $$DownloadCollectionSyncsTableOrderingComposer,
          $$DownloadCollectionSyncsTableAnnotationComposer,
          $$DownloadCollectionSyncsTableCreateCompanionBuilder,
          $$DownloadCollectionSyncsTableUpdateCompanionBuilder,
          (
            DownloadCollectionSyncItem,
            BaseReferences<
              _$AppDatabase,
              $DownloadCollectionSyncsTable,
              DownloadCollectionSyncItem
            >,
          ),
          DownloadCollectionSyncItem,
          PrefetchHooks Function()
        > {
  $$DownloadCollectionSyncsTableTableManager(
    _$AppDatabase db,
    $DownloadCollectionSyncsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$DownloadCollectionSyncsTableFilterComposer(
                $db: db,
                $table: table,
              ),
          createOrderingComposer: () =>
              $$DownloadCollectionSyncsTableOrderingComposer(
                $db: db,
                $table: table,
              ),
          createComputedFieldComposer: () =>
              $$DownloadCollectionSyncsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<String> serverId = const Value.absent(),
                Value<int> syncedAt = const Value.absent(),
                Value<String> checkedIds = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => DownloadCollectionSyncsCompanion(
                profileId: profileId,
                serverId: serverId,
                syncedAt: syncedAt,
                checkedIds: checkedIds,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required String serverId,
                required int syncedAt,
                required String checkedIds,
                Value<int> rowid = const Value.absent(),
              }) => DownloadCollectionSyncsCompanion.insert(
                profileId: profileId,
                serverId: serverId,
                syncedAt: syncedAt,
                checkedIds: checkedIds,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$DownloadCollectionSyncsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $DownloadCollectionSyncsTable,
      DownloadCollectionSyncItem,
      $$DownloadCollectionSyncsTableFilterComposer,
      $$DownloadCollectionSyncsTableOrderingComposer,
      $$DownloadCollectionSyncsTableAnnotationComposer,
      $$DownloadCollectionSyncsTableCreateCompanionBuilder,
      $$DownloadCollectionSyncsTableUpdateCompanionBuilder,
      (
        DownloadCollectionSyncItem,
        BaseReferences<
          _$AppDatabase,
          $DownloadCollectionSyncsTable,
          DownloadCollectionSyncItem
        >,
      ),
      DownloadCollectionSyncItem,
      PrefetchHooks Function()
    >;
typedef $$ConnectionsTableCreateCompanionBuilder =
    ConnectionsCompanion Function({
      required String id,
      required String kind,
      required String displayName,
      required String configJson,
      required int createdAt,
      Value<int?> lastAuthenticatedAt,
      Value<int> rowid,
    });
typedef $$ConnectionsTableUpdateCompanionBuilder =
    ConnectionsCompanion Function({
      Value<String> id,
      Value<String> kind,
      Value<String> displayName,
      Value<String> configJson,
      Value<int> createdAt,
      Value<int?> lastAuthenticatedAt,
      Value<int> rowid,
    });

final class $$ConnectionsTableReferences
    extends BaseReferences<_$AppDatabase, $ConnectionsTable, ConnectionRow> {
  $$ConnectionsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<
    $ProfileConnectionsTable,
    List<ProfileConnectionRow>
  >
  _profileConnectionsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.profileConnections,
        aliasName: 'connections__id__profile_connections__connection_id',
      );

  $$ProfileConnectionsTableProcessedTableManager get profileConnectionsRefs {
    final manager = $$ProfileConnectionsTableTableManager(
      $_db,
      $_db.profileConnections,
    ).filter((f) => f.connectionId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _profileConnectionsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$ConnectionsTableFilterComposer
    extends Composer<_$AppDatabase, $ConnectionsTable> {
  $$ConnectionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastAuthenticatedAt => $composableBuilder(
    column: $table.lastAuthenticatedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> profileConnectionsRefs(
    Expression<bool> Function($$ProfileConnectionsTableFilterComposer f) f,
  ) {
    final $$ProfileConnectionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.profileConnections,
      getReferencedColumn: (t) => t.connectionId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ProfileConnectionsTableFilterComposer(
            $db: $db,
            $table: $db.profileConnections,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ConnectionsTableOrderingComposer
    extends Composer<_$AppDatabase, $ConnectionsTable> {
  $$ConnectionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastAuthenticatedAt => $composableBuilder(
    column: $table.lastAuthenticatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ConnectionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ConnectionsTable> {
  $$ConnectionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get lastAuthenticatedAt => $composableBuilder(
    column: $table.lastAuthenticatedAt,
    builder: (column) => column,
  );

  Expression<T> profileConnectionsRefs<T extends Object>(
    Expression<T> Function($$ProfileConnectionsTableAnnotationComposer a) f,
  ) {
    final $$ProfileConnectionsTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.profileConnections,
          getReferencedColumn: (t) => t.connectionId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$ProfileConnectionsTableAnnotationComposer(
                $db: $db,
                $table: $db.profileConnections,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$ConnectionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ConnectionsTable,
          ConnectionRow,
          $$ConnectionsTableFilterComposer,
          $$ConnectionsTableOrderingComposer,
          $$ConnectionsTableAnnotationComposer,
          $$ConnectionsTableCreateCompanionBuilder,
          $$ConnectionsTableUpdateCompanionBuilder,
          (ConnectionRow, $$ConnectionsTableReferences),
          ConnectionRow,
          PrefetchHooks Function({bool profileConnectionsRefs})
        > {
  $$ConnectionsTableTableManager(_$AppDatabase db, $ConnectionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ConnectionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ConnectionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ConnectionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> configJson = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int?> lastAuthenticatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConnectionsCompanion(
                id: id,
                kind: kind,
                displayName: displayName,
                configJson: configJson,
                createdAt: createdAt,
                lastAuthenticatedAt: lastAuthenticatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String kind,
                required String displayName,
                required String configJson,
                required int createdAt,
                Value<int?> lastAuthenticatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConnectionsCompanion.insert(
                id: id,
                kind: kind,
                displayName: displayName,
                configJson: configJson,
                createdAt: createdAt,
                lastAuthenticatedAt: lastAuthenticatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ConnectionsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({profileConnectionsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (profileConnectionsRefs) db.profileConnections,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (profileConnectionsRefs)
                    await $_getPrefetchedData<
                      ConnectionRow,
                      $ConnectionsTable,
                      ProfileConnectionRow
                    >(
                      currentTable: table,
                      referencedTable: $$ConnectionsTableReferences
                          ._profileConnectionsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$ConnectionsTableReferences(
                            db,
                            table,
                            p0,
                          ).profileConnectionsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where(
                            (e) => e.connectionId == item.id,
                          ),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$ConnectionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ConnectionsTable,
      ConnectionRow,
      $$ConnectionsTableFilterComposer,
      $$ConnectionsTableOrderingComposer,
      $$ConnectionsTableAnnotationComposer,
      $$ConnectionsTableCreateCompanionBuilder,
      $$ConnectionsTableUpdateCompanionBuilder,
      (ConnectionRow, $$ConnectionsTableReferences),
      ConnectionRow,
      PrefetchHooks Function({bool profileConnectionsRefs})
    >;
typedef $$ProfilesTableCreateCompanionBuilder =
    ProfilesCompanion Function({
      required String id,
      required String kind,
      required String displayName,
      Value<String?> avatarThumbUrl,
      required String configJson,
      Value<int> sortOrder,
      required int createdAt,
      Value<int?> lastUsedAt,
      Value<int> rowid,
    });
typedef $$ProfilesTableUpdateCompanionBuilder =
    ProfilesCompanion Function({
      Value<String> id,
      Value<String> kind,
      Value<String> displayName,
      Value<String?> avatarThumbUrl,
      Value<String> configJson,
      Value<int> sortOrder,
      Value<int> createdAt,
      Value<int?> lastUsedAt,
      Value<int> rowid,
    });

class $$ProfilesTableFilterComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get avatarThumbUrl => $composableBuilder(
    column: $table.avatarThumbUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$ProfilesTableOrderingComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get avatarThumbUrl => $composableBuilder(
    column: $table.avatarThumbUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$ProfilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProfilesTable> {
  $$ProfilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get avatarThumbUrl => $composableBuilder(
    column: $table.avatarThumbUrl,
    builder: (column) => column,
  );

  GeneratedColumn<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => column,
  );

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => column,
  );
}

class $$ProfilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProfilesTable,
          ProfileRow,
          $$ProfilesTableFilterComposer,
          $$ProfilesTableOrderingComposer,
          $$ProfilesTableAnnotationComposer,
          $$ProfilesTableCreateCompanionBuilder,
          $$ProfilesTableUpdateCompanionBuilder,
          (
            ProfileRow,
            BaseReferences<_$AppDatabase, $ProfilesTable, ProfileRow>,
          ),
          ProfileRow,
          PrefetchHooks Function()
        > {
  $$ProfilesTableTableManager(_$AppDatabase db, $ProfilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProfilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String?> avatarThumbUrl = const Value.absent(),
                Value<String> configJson = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int?> lastUsedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfilesCompanion(
                id: id,
                kind: kind,
                displayName: displayName,
                avatarThumbUrl: avatarThumbUrl,
                configJson: configJson,
                sortOrder: sortOrder,
                createdAt: createdAt,
                lastUsedAt: lastUsedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String kind,
                required String displayName,
                Value<String?> avatarThumbUrl = const Value.absent(),
                required String configJson,
                Value<int> sortOrder = const Value.absent(),
                required int createdAt,
                Value<int?> lastUsedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfilesCompanion.insert(
                id: id,
                kind: kind,
                displayName: displayName,
                avatarThumbUrl: avatarThumbUrl,
                configJson: configJson,
                sortOrder: sortOrder,
                createdAt: createdAt,
                lastUsedAt: lastUsedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$ProfilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProfilesTable,
      ProfileRow,
      $$ProfilesTableFilterComposer,
      $$ProfilesTableOrderingComposer,
      $$ProfilesTableAnnotationComposer,
      $$ProfilesTableCreateCompanionBuilder,
      $$ProfilesTableUpdateCompanionBuilder,
      (ProfileRow, BaseReferences<_$AppDatabase, $ProfilesTable, ProfileRow>),
      ProfileRow,
      PrefetchHooks Function()
    >;
typedef $$ProfileConnectionsTableCreateCompanionBuilder =
    ProfileConnectionsCompanion Function({
      required String profileId,
      required String connectionId,
      Value<String> userToken,
      required String userIdentifier,
      Value<bool> isDefault,
      Value<int?> tokenAcquiredAt,
      Value<int?> lastUsedAt,
      Value<int> rowid,
    });
typedef $$ProfileConnectionsTableUpdateCompanionBuilder =
    ProfileConnectionsCompanion Function({
      Value<String> profileId,
      Value<String> connectionId,
      Value<String> userToken,
      Value<String> userIdentifier,
      Value<bool> isDefault,
      Value<int?> tokenAcquiredAt,
      Value<int?> lastUsedAt,
      Value<int> rowid,
    });

final class $$ProfileConnectionsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $ProfileConnectionsTable,
          ProfileConnectionRow
        > {
  $$ProfileConnectionsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $ConnectionsTable _connectionIdTable(_$AppDatabase db) => db
      .connections
      .createAlias('profile_connections__connection_id__connections__id');

  $$ConnectionsTableProcessedTableManager get connectionId {
    final $_column = $_itemColumn<String>('connection_id')!;

    final manager = $$ConnectionsTableTableManager(
      $_db,
      $_db.connections,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_connectionIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$ProfileConnectionsTableFilterComposer
    extends Composer<_$AppDatabase, $ProfileConnectionsTable> {
  $$ProfileConnectionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userToken => $composableBuilder(
    column: $table.userToken,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userIdentifier => $composableBuilder(
    column: $table.userIdentifier,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get tokenAcquiredAt => $composableBuilder(
    column: $table.tokenAcquiredAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$ConnectionsTableFilterComposer get connectionId {
    final $$ConnectionsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.connectionId,
      referencedTable: $db.connections,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConnectionsTableFilterComposer(
            $db: $db,
            $table: $db.connections,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProfileConnectionsTableOrderingComposer
    extends Composer<_$AppDatabase, $ProfileConnectionsTable> {
  $$ProfileConnectionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userToken => $composableBuilder(
    column: $table.userToken,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userIdentifier => $composableBuilder(
    column: $table.userIdentifier,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get isDefault => $composableBuilder(
    column: $table.isDefault,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get tokenAcquiredAt => $composableBuilder(
    column: $table.tokenAcquiredAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$ConnectionsTableOrderingComposer get connectionId {
    final $$ConnectionsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.connectionId,
      referencedTable: $db.connections,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConnectionsTableOrderingComposer(
            $db: $db,
            $table: $db.connections,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProfileConnectionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $ProfileConnectionsTable> {
  $$ProfileConnectionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get userToken =>
      $composableBuilder(column: $table.userToken, builder: (column) => column);

  GeneratedColumn<String> get userIdentifier => $composableBuilder(
    column: $table.userIdentifier,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get isDefault =>
      $composableBuilder(column: $table.isDefault, builder: (column) => column);

  GeneratedColumn<int> get tokenAcquiredAt => $composableBuilder(
    column: $table.tokenAcquiredAt,
    builder: (column) => column,
  );

  GeneratedColumn<int> get lastUsedAt => $composableBuilder(
    column: $table.lastUsedAt,
    builder: (column) => column,
  );

  $$ConnectionsTableAnnotationComposer get connectionId {
    final $$ConnectionsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.connectionId,
      referencedTable: $db.connections,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$ConnectionsTableAnnotationComposer(
            $db: $db,
            $table: $db.connections,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$ProfileConnectionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ProfileConnectionsTable,
          ProfileConnectionRow,
          $$ProfileConnectionsTableFilterComposer,
          $$ProfileConnectionsTableOrderingComposer,
          $$ProfileConnectionsTableAnnotationComposer,
          $$ProfileConnectionsTableCreateCompanionBuilder,
          $$ProfileConnectionsTableUpdateCompanionBuilder,
          (ProfileConnectionRow, $$ProfileConnectionsTableReferences),
          ProfileConnectionRow,
          PrefetchHooks Function({bool connectionId})
        > {
  $$ProfileConnectionsTableTableManager(
    _$AppDatabase db,
    $ProfileConnectionsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$ProfileConnectionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$ProfileConnectionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$ProfileConnectionsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<String> connectionId = const Value.absent(),
                Value<String> userToken = const Value.absent(),
                Value<String> userIdentifier = const Value.absent(),
                Value<bool> isDefault = const Value.absent(),
                Value<int?> tokenAcquiredAt = const Value.absent(),
                Value<int?> lastUsedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfileConnectionsCompanion(
                profileId: profileId,
                connectionId: connectionId,
                userToken: userToken,
                userIdentifier: userIdentifier,
                isDefault: isDefault,
                tokenAcquiredAt: tokenAcquiredAt,
                lastUsedAt: lastUsedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required String connectionId,
                Value<String> userToken = const Value.absent(),
                required String userIdentifier,
                Value<bool> isDefault = const Value.absent(),
                Value<int?> tokenAcquiredAt = const Value.absent(),
                Value<int?> lastUsedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ProfileConnectionsCompanion.insert(
                profileId: profileId,
                connectionId: connectionId,
                userToken: userToken,
                userIdentifier: userIdentifier,
                isDefault: isDefault,
                tokenAcquiredAt: tokenAcquiredAt,
                lastUsedAt: lastUsedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$ProfileConnectionsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({connectionId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (connectionId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.connectionId,
                                referencedTable:
                                    $$ProfileConnectionsTableReferences
                                        ._connectionIdTable(db),
                                referencedColumn:
                                    $$ProfileConnectionsTableReferences
                                        ._connectionIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$ProfileConnectionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ProfileConnectionsTable,
      ProfileConnectionRow,
      $$ProfileConnectionsTableFilterComposer,
      $$ProfileConnectionsTableOrderingComposer,
      $$ProfileConnectionsTableAnnotationComposer,
      $$ProfileConnectionsTableCreateCompanionBuilder,
      $$ProfileConnectionsTableUpdateCompanionBuilder,
      (ProfileConnectionRow, $$ProfileConnectionsTableReferences),
      ProfileConnectionRow,
      PrefetchHooks Function({bool connectionId})
    >;
typedef $$MusicSessionsTableCreateCompanionBuilder =
    MusicSessionsCompanion Function({
      required String profileId,
      required String queueJson,
      required String orderJson,
      required int cursor,
      Value<bool> shuffled,
      Value<String> repeatMode,
      Value<String?> contextTitle,
      Value<String?> contextKind,
      Value<int> positionMs,
      required int updatedAt,
      Value<int> rowid,
    });
typedef $$MusicSessionsTableUpdateCompanionBuilder =
    MusicSessionsCompanion Function({
      Value<String> profileId,
      Value<String> queueJson,
      Value<String> orderJson,
      Value<int> cursor,
      Value<bool> shuffled,
      Value<String> repeatMode,
      Value<String?> contextTitle,
      Value<String?> contextKind,
      Value<int> positionMs,
      Value<int> updatedAt,
      Value<int> rowid,
    });

class $$MusicSessionsTableFilterComposer
    extends Composer<_$AppDatabase, $MusicSessionsTable> {
  $$MusicSessionsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get queueJson => $composableBuilder(
    column: $table.queueJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get orderJson => $composableBuilder(
    column: $table.orderJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get shuffled => $composableBuilder(
    column: $table.shuffled,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get repeatMode => $composableBuilder(
    column: $table.repeatMode,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contextTitle => $composableBuilder(
    column: $table.contextTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contextKind => $composableBuilder(
    column: $table.contextKind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$MusicSessionsTableOrderingComposer
    extends Composer<_$AppDatabase, $MusicSessionsTable> {
  $$MusicSessionsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get profileId => $composableBuilder(
    column: $table.profileId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get queueJson => $composableBuilder(
    column: $table.queueJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get orderJson => $composableBuilder(
    column: $table.orderJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get cursor => $composableBuilder(
    column: $table.cursor,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get shuffled => $composableBuilder(
    column: $table.shuffled,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get repeatMode => $composableBuilder(
    column: $table.repeatMode,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contextTitle => $composableBuilder(
    column: $table.contextTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contextKind => $composableBuilder(
    column: $table.contextKind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MusicSessionsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MusicSessionsTable> {
  $$MusicSessionsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get profileId =>
      $composableBuilder(column: $table.profileId, builder: (column) => column);

  GeneratedColumn<String> get queueJson =>
      $composableBuilder(column: $table.queueJson, builder: (column) => column);

  GeneratedColumn<String> get orderJson =>
      $composableBuilder(column: $table.orderJson, builder: (column) => column);

  GeneratedColumn<int> get cursor =>
      $composableBuilder(column: $table.cursor, builder: (column) => column);

  GeneratedColumn<bool> get shuffled =>
      $composableBuilder(column: $table.shuffled, builder: (column) => column);

  GeneratedColumn<String> get repeatMode => $composableBuilder(
    column: $table.repeatMode,
    builder: (column) => column,
  );

  GeneratedColumn<String> get contextTitle => $composableBuilder(
    column: $table.contextTitle,
    builder: (column) => column,
  );

  GeneratedColumn<String> get contextKind => $composableBuilder(
    column: $table.contextKind,
    builder: (column) => column,
  );

  GeneratedColumn<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);
}

class $$MusicSessionsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MusicSessionsTable,
          MusicSessionRow,
          $$MusicSessionsTableFilterComposer,
          $$MusicSessionsTableOrderingComposer,
          $$MusicSessionsTableAnnotationComposer,
          $$MusicSessionsTableCreateCompanionBuilder,
          $$MusicSessionsTableUpdateCompanionBuilder,
          (
            MusicSessionRow,
            BaseReferences<_$AppDatabase, $MusicSessionsTable, MusicSessionRow>,
          ),
          MusicSessionRow,
          PrefetchHooks Function()
        > {
  $$MusicSessionsTableTableManager(_$AppDatabase db, $MusicSessionsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MusicSessionsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MusicSessionsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MusicSessionsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> profileId = const Value.absent(),
                Value<String> queueJson = const Value.absent(),
                Value<String> orderJson = const Value.absent(),
                Value<int> cursor = const Value.absent(),
                Value<bool> shuffled = const Value.absent(),
                Value<String> repeatMode = const Value.absent(),
                Value<String?> contextTitle = const Value.absent(),
                Value<String?> contextKind = const Value.absent(),
                Value<int> positionMs = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MusicSessionsCompanion(
                profileId: profileId,
                queueJson: queueJson,
                orderJson: orderJson,
                cursor: cursor,
                shuffled: shuffled,
                repeatMode: repeatMode,
                contextTitle: contextTitle,
                contextKind: contextKind,
                positionMs: positionMs,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String profileId,
                required String queueJson,
                required String orderJson,
                required int cursor,
                Value<bool> shuffled = const Value.absent(),
                Value<String> repeatMode = const Value.absent(),
                Value<String?> contextTitle = const Value.absent(),
                Value<String?> contextKind = const Value.absent(),
                Value<int> positionMs = const Value.absent(),
                required int updatedAt,
                Value<int> rowid = const Value.absent(),
              }) => MusicSessionsCompanion.insert(
                profileId: profileId,
                queueJson: queueJson,
                orderJson: orderJson,
                cursor: cursor,
                shuffled: shuffled,
                repeatMode: repeatMode,
                contextTitle: contextTitle,
                contextKind: contextKind,
                positionMs: positionMs,
                updatedAt: updatedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$MusicSessionsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MusicSessionsTable,
      MusicSessionRow,
      $$MusicSessionsTableFilterComposer,
      $$MusicSessionsTableOrderingComposer,
      $$MusicSessionsTableAnnotationComposer,
      $$MusicSessionsTableCreateCompanionBuilder,
      $$MusicSessionsTableUpdateCompanionBuilder,
      (
        MusicSessionRow,
        BaseReferences<_$AppDatabase, $MusicSessionsTable, MusicSessionRow>,
      ),
      MusicSessionRow,
      PrefetchHooks Function()
    >;
typedef $$MountsTableCreateCompanionBuilder =
    MountsCompanion Function({
      required String id,
      required String kind,
      required String displayName,
      Value<String> libraryType,
      required String configJson,
      Value<String> secrets,
      required int createdAt,
      Value<int> rowid,
    });
typedef $$MountsTableUpdateCompanionBuilder =
    MountsCompanion Function({
      Value<String> id,
      Value<String> kind,
      Value<String> displayName,
      Value<String> libraryType,
      Value<String> configJson,
      Value<String> secrets,
      Value<int> createdAt,
      Value<int> rowid,
    });

final class $$MountsTableReferences
    extends BaseReferences<_$AppDatabase, $MountsTable, MountRow> {
  $$MountsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$LibraryFilesTable, List<LibraryFileRow>>
  _libraryFilesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.libraryFiles,
    aliasName: 'mounts__id__library_files__mount_id',
  );

  $$LibraryFilesTableProcessedTableManager get libraryFilesRefs {
    final manager = $$LibraryFilesTableTableManager(
      $_db,
      $_db.libraryFiles,
    ).filter((f) => f.mountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_libraryFilesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$LibraryScanStatesTable, List<LibraryScanStateRow>>
  _libraryScanStatesRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.libraryScanStates,
        aliasName: 'mounts__id__library_scan_states__mount_id',
      );

  $$LibraryScanStatesTableProcessedTableManager get libraryScanStatesRefs {
    final manager = $$LibraryScanStatesTableTableManager(
      $_db,
      $_db.libraryScanStates,
    ).filter((f) => f.mountId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _libraryScanStatesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$MountsTableFilterComposer
    extends Composer<_$AppDatabase, $MountsTable> {
  $$MountsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get libraryType => $composableBuilder(
    column: $table.libraryType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get secrets => $composableBuilder(
    column: $table.secrets,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> libraryFilesRefs(
    Expression<bool> Function($$LibraryFilesTableFilterComposer f) f,
  ) {
    final $$LibraryFilesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryFiles,
      getReferencedColumn: (t) => t.mountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryFilesTableFilterComposer(
            $db: $db,
            $table: $db.libraryFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> libraryScanStatesRefs(
    Expression<bool> Function($$LibraryScanStatesTableFilterComposer f) f,
  ) {
    final $$LibraryScanStatesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryScanStates,
      getReferencedColumn: (t) => t.mountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryScanStatesTableFilterComposer(
            $db: $db,
            $table: $db.libraryScanStates,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MountsTableOrderingComposer
    extends Composer<_$AppDatabase, $MountsTable> {
  $$MountsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get libraryType => $composableBuilder(
    column: $table.libraryType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get secrets => $composableBuilder(
    column: $table.secrets,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$MountsTableAnnotationComposer
    extends Composer<_$AppDatabase, $MountsTable> {
  $$MountsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get displayName => $composableBuilder(
    column: $table.displayName,
    builder: (column) => column,
  );

  GeneratedColumn<String> get libraryType => $composableBuilder(
    column: $table.libraryType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get configJson => $composableBuilder(
    column: $table.configJson,
    builder: (column) => column,
  );

  GeneratedColumn<String> get secrets =>
      $composableBuilder(column: $table.secrets, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  Expression<T> libraryFilesRefs<T extends Object>(
    Expression<T> Function($$LibraryFilesTableAnnotationComposer a) f,
  ) {
    final $$LibraryFilesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryFiles,
      getReferencedColumn: (t) => t.mountId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryFilesTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> libraryScanStatesRefs<T extends Object>(
    Expression<T> Function($$LibraryScanStatesTableAnnotationComposer a) f,
  ) {
    final $$LibraryScanStatesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.libraryScanStates,
          getReferencedColumn: (t) => t.mountId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$LibraryScanStatesTableAnnotationComposer(
                $db: $db,
                $table: $db.libraryScanStates,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$MountsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MountsTable,
          MountRow,
          $$MountsTableFilterComposer,
          $$MountsTableOrderingComposer,
          $$MountsTableAnnotationComposer,
          $$MountsTableCreateCompanionBuilder,
          $$MountsTableUpdateCompanionBuilder,
          (MountRow, $$MountsTableReferences),
          MountRow,
          PrefetchHooks Function({
            bool libraryFilesRefs,
            bool libraryScanStatesRefs,
          })
        > {
  $$MountsTableTableManager(_$AppDatabase db, $MountsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$MountsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$MountsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$MountsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> displayName = const Value.absent(),
                Value<String> libraryType = const Value.absent(),
                Value<String> configJson = const Value.absent(),
                Value<String> secrets = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MountsCompanion(
                id: id,
                kind: kind,
                displayName: displayName,
                libraryType: libraryType,
                configJson: configJson,
                secrets: secrets,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String kind,
                required String displayName,
                Value<String> libraryType = const Value.absent(),
                required String configJson,
                Value<String> secrets = const Value.absent(),
                required int createdAt,
                Value<int> rowid = const Value.absent(),
              }) => MountsCompanion.insert(
                id: id,
                kind: kind,
                displayName: displayName,
                libraryType: libraryType,
                configJson: configJson,
                secrets: secrets,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) =>
                    (e.readTable(table), $$MountsTableReferences(db, table, e)),
              )
              .toList(),
          prefetchHooksCallback:
              ({libraryFilesRefs = false, libraryScanStatesRefs = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (libraryFilesRefs) db.libraryFiles,
                    if (libraryScanStatesRefs) db.libraryScanStates,
                  ],
                  addJoins: null,
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (libraryFilesRefs)
                        await $_getPrefetchedData<
                          MountRow,
                          $MountsTable,
                          LibraryFileRow
                        >(
                          currentTable: table,
                          referencedTable: $$MountsTableReferences
                              ._libraryFilesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MountsTableReferences(
                                db,
                                table,
                                p0,
                              ).libraryFilesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.mountId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (libraryScanStatesRefs)
                        await $_getPrefetchedData<
                          MountRow,
                          $MountsTable,
                          LibraryScanStateRow
                        >(
                          currentTable: table,
                          referencedTable: $$MountsTableReferences
                              ._libraryScanStatesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$MountsTableReferences(
                                db,
                                table,
                                p0,
                              ).libraryScanStatesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.mountId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$MountsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MountsTable,
      MountRow,
      $$MountsTableFilterComposer,
      $$MountsTableOrderingComposer,
      $$MountsTableAnnotationComposer,
      $$MountsTableCreateCompanionBuilder,
      $$MountsTableUpdateCompanionBuilder,
      (MountRow, $$MountsTableReferences),
      MountRow,
      PrefetchHooks Function({
        bool libraryFilesRefs,
        bool libraryScanStatesRefs,
      })
    >;
typedef $$LibraryItemsTableCreateCompanionBuilder =
    LibraryItemsCompanion Function({
      Value<int> id,
      required String kind,
      required String libraryType,
      Value<int?> parentId,
      Value<int?> showId,
      required String title,
      required String sortTitle,
      Value<String?> originalTitle,
      Value<String?> aliases,
      Value<int?> year,
      Value<String?> releaseDate,
      Value<String?> summary,
      Value<String?> tagline,
      Value<String?> contentRating,
      Value<String?> studio,
      Value<double?> rating,
      Value<int?> runtimeMs,
      Value<int?> seasonNumber,
      Value<int?> episodeNumber,
      Value<int?> absoluteNumber,
      Value<String?> posterSource,
      Value<String?> backdropSource,
      Value<String?> logoSource,
      Value<String?> tmdbId,
      Value<String?> imdbId,
      Value<String?> tvdbId,
      Value<String?> bangumiId,
      Value<String?> doubanId,
      Value<String?> metadataSource,
      Value<bool> locked,
      required int addedAt,
      required int updatedAt,
      Value<int?> scrapedAt,
    });
typedef $$LibraryItemsTableUpdateCompanionBuilder =
    LibraryItemsCompanion Function({
      Value<int> id,
      Value<String> kind,
      Value<String> libraryType,
      Value<int?> parentId,
      Value<int?> showId,
      Value<String> title,
      Value<String> sortTitle,
      Value<String?> originalTitle,
      Value<String?> aliases,
      Value<int?> year,
      Value<String?> releaseDate,
      Value<String?> summary,
      Value<String?> tagline,
      Value<String?> contentRating,
      Value<String?> studio,
      Value<double?> rating,
      Value<int?> runtimeMs,
      Value<int?> seasonNumber,
      Value<int?> episodeNumber,
      Value<int?> absoluteNumber,
      Value<String?> posterSource,
      Value<String?> backdropSource,
      Value<String?> logoSource,
      Value<String?> tmdbId,
      Value<String?> imdbId,
      Value<String?> tvdbId,
      Value<String?> bangumiId,
      Value<String?> doubanId,
      Value<String?> metadataSource,
      Value<bool> locked,
      Value<int> addedAt,
      Value<int> updatedAt,
      Value<int?> scrapedAt,
    });

final class $$LibraryItemsTableReferences
    extends BaseReferences<_$AppDatabase, $LibraryItemsTable, LibraryItemRow> {
  $$LibraryItemsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $LibraryItemsTable _parentIdTable(_$AppDatabase db) => db.libraryItems
      .createAlias('library_items__parent_id__library_items__id');

  $$LibraryItemsTableProcessedTableManager? get parentId {
    final $_column = $_itemColumn<int>('parent_id');
    if ($_column == null) return null;
    final manager = $$LibraryItemsTableTableManager(
      $_db,
      $_db.libraryItems,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_parentIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $LibraryItemsTable _showIdTable(_$AppDatabase db) =>
      db.libraryItems.createAlias('library_items__show_id__library_items__id');

  $$LibraryItemsTableProcessedTableManager? get showId {
    final $_column = $_itemColumn<int>('show_id');
    if ($_column == null) return null;
    final manager = $$LibraryItemsTableTableManager(
      $_db,
      $_db.libraryItems,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_showIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static MultiTypedResultKey<$LibraryFilesTable, List<LibraryFileRow>>
  _libraryFilesRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.libraryFiles,
    aliasName: 'library_items__id__library_files__item_id',
  );

  $$LibraryFilesTableProcessedTableManager get libraryFilesRefs {
    final manager = $$LibraryFilesTableTableManager(
      $_db,
      $_db.libraryFiles,
    ).filter((f) => f.itemId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_libraryFilesRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$LibraryUserStatesTable, List<LibraryUserStateRow>>
  _libraryUserStatesRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.libraryUserStates,
        aliasName: 'library_items__id__library_user_states__item_id',
      );

  $$LibraryUserStatesTableProcessedTableManager get libraryUserStatesRefs {
    final manager = $$LibraryUserStatesTableTableManager(
      $_db,
      $_db.libraryUserStates,
    ).filter((f) => f.itemId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _libraryUserStatesRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$LibraryItemGenresTable, List<LibraryItemGenreRow>>
  _libraryItemGenresRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.libraryItemGenres,
        aliasName: 'library_items__id__library_item_genres__item_id',
      );

  $$LibraryItemGenresTableProcessedTableManager get libraryItemGenresRefs {
    final manager = $$LibraryItemGenresTableTableManager(
      $_db,
      $_db.libraryItemGenres,
    ).filter((f) => f.itemId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _libraryItemGenresRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$LibraryCreditsTable, List<LibraryCreditRow>>
  _libraryCreditsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.libraryCredits,
    aliasName: 'library_items__id__library_credits__item_id',
  );

  $$LibraryCreditsTableProcessedTableManager get libraryCreditsRefs {
    final manager = $$LibraryCreditsTableTableManager(
      $_db,
      $_db.libraryCredits,
    ).filter((f) => f.itemId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_libraryCreditsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }

  static MultiTypedResultKey<$LibraryListItemsTable, List<LibraryListItemRow>>
  _libraryListItemsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.libraryListItems,
    aliasName: 'library_items__id__library_list_items__item_id',
  );

  $$LibraryListItemsTableProcessedTableManager get libraryListItemsRefs {
    final manager = $$LibraryListItemsTableTableManager(
      $_db,
      $_db.libraryListItems,
    ).filter((f) => f.itemId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _libraryListItemsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$LibraryItemsTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryItemsTable> {
  $$LibraryItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get libraryType => $composableBuilder(
    column: $table.libraryType,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get sortTitle => $composableBuilder(
    column: $table.sortTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get aliases => $composableBuilder(
    column: $table.aliases,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get releaseDate => $composableBuilder(
    column: $table.releaseDate,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tagline => $composableBuilder(
    column: $table.tagline,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get contentRating => $composableBuilder(
    column: $table.contentRating,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get studio => $composableBuilder(
    column: $table.studio,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<double> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get runtimeMs => $composableBuilder(
    column: $table.runtimeMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get absoluteNumber => $composableBuilder(
    column: $table.absoluteNumber,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get posterSource => $composableBuilder(
    column: $table.posterSource,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get backdropSource => $composableBuilder(
    column: $table.backdropSource,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get logoSource => $composableBuilder(
    column: $table.logoSource,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get imdbId => $composableBuilder(
    column: $table.imdbId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tvdbId => $composableBuilder(
    column: $table.tvdbId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get bangumiId => $composableBuilder(
    column: $table.bangumiId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get doubanId => $composableBuilder(
    column: $table.doubanId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get metadataSource => $composableBuilder(
    column: $table.metadataSource,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get locked => $composableBuilder(
    column: $table.locked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get scrapedAt => $composableBuilder(
    column: $table.scrapedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LibraryItemsTableFilterComposer get parentId {
    final $$LibraryItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableFilterComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryItemsTableFilterComposer get showId {
    final $$LibraryItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.showId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableFilterComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> libraryFilesRefs(
    Expression<bool> Function($$LibraryFilesTableFilterComposer f) f,
  ) {
    final $$LibraryFilesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryFiles,
      getReferencedColumn: (t) => t.itemId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryFilesTableFilterComposer(
            $db: $db,
            $table: $db.libraryFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> libraryUserStatesRefs(
    Expression<bool> Function($$LibraryUserStatesTableFilterComposer f) f,
  ) {
    final $$LibraryUserStatesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryUserStates,
      getReferencedColumn: (t) => t.itemId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryUserStatesTableFilterComposer(
            $db: $db,
            $table: $db.libraryUserStates,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> libraryItemGenresRefs(
    Expression<bool> Function($$LibraryItemGenresTableFilterComposer f) f,
  ) {
    final $$LibraryItemGenresTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryItemGenres,
      getReferencedColumn: (t) => t.itemId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemGenresTableFilterComposer(
            $db: $db,
            $table: $db.libraryItemGenres,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> libraryCreditsRefs(
    Expression<bool> Function($$LibraryCreditsTableFilterComposer f) f,
  ) {
    final $$LibraryCreditsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryCredits,
      getReferencedColumn: (t) => t.itemId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryCreditsTableFilterComposer(
            $db: $db,
            $table: $db.libraryCredits,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<bool> libraryListItemsRefs(
    Expression<bool> Function($$LibraryListItemsTableFilterComposer f) f,
  ) {
    final $$LibraryListItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryListItems,
      getReferencedColumn: (t) => t.itemId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryListItemsTableFilterComposer(
            $db: $db,
            $table: $db.libraryListItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LibraryItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryItemsTable> {
  $$LibraryItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get libraryType => $composableBuilder(
    column: $table.libraryType,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get sortTitle => $composableBuilder(
    column: $table.sortTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get aliases => $composableBuilder(
    column: $table.aliases,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get year => $composableBuilder(
    column: $table.year,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get releaseDate => $composableBuilder(
    column: $table.releaseDate,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tagline => $composableBuilder(
    column: $table.tagline,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get contentRating => $composableBuilder(
    column: $table.contentRating,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get studio => $composableBuilder(
    column: $table.studio,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<double> get rating => $composableBuilder(
    column: $table.rating,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get runtimeMs => $composableBuilder(
    column: $table.runtimeMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get absoluteNumber => $composableBuilder(
    column: $table.absoluteNumber,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get posterSource => $composableBuilder(
    column: $table.posterSource,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get backdropSource => $composableBuilder(
    column: $table.backdropSource,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get logoSource => $composableBuilder(
    column: $table.logoSource,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get imdbId => $composableBuilder(
    column: $table.imdbId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tvdbId => $composableBuilder(
    column: $table.tvdbId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get bangumiId => $composableBuilder(
    column: $table.bangumiId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get doubanId => $composableBuilder(
    column: $table.doubanId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get metadataSource => $composableBuilder(
    column: $table.metadataSource,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get locked => $composableBuilder(
    column: $table.locked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get scrapedAt => $composableBuilder(
    column: $table.scrapedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LibraryItemsTableOrderingComposer get parentId {
    final $$LibraryItemsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableOrderingComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryItemsTableOrderingComposer get showId {
    final $$LibraryItemsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.showId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableOrderingComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryItemsTable> {
  $$LibraryItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get libraryType => $composableBuilder(
    column: $table.libraryType,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get sortTitle =>
      $composableBuilder(column: $table.sortTitle, builder: (column) => column);

  GeneratedColumn<String> get originalTitle => $composableBuilder(
    column: $table.originalTitle,
    builder: (column) => column,
  );

  GeneratedColumn<String> get aliases =>
      $composableBuilder(column: $table.aliases, builder: (column) => column);

  GeneratedColumn<int> get year =>
      $composableBuilder(column: $table.year, builder: (column) => column);

  GeneratedColumn<String> get releaseDate => $composableBuilder(
    column: $table.releaseDate,
    builder: (column) => column,
  );

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<String> get tagline =>
      $composableBuilder(column: $table.tagline, builder: (column) => column);

  GeneratedColumn<String> get contentRating => $composableBuilder(
    column: $table.contentRating,
    builder: (column) => column,
  );

  GeneratedColumn<String> get studio =>
      $composableBuilder(column: $table.studio, builder: (column) => column);

  GeneratedColumn<double> get rating =>
      $composableBuilder(column: $table.rating, builder: (column) => column);

  GeneratedColumn<int> get runtimeMs =>
      $composableBuilder(column: $table.runtimeMs, builder: (column) => column);

  GeneratedColumn<int> get seasonNumber => $composableBuilder(
    column: $table.seasonNumber,
    builder: (column) => column,
  );

  GeneratedColumn<int> get episodeNumber => $composableBuilder(
    column: $table.episodeNumber,
    builder: (column) => column,
  );

  GeneratedColumn<int> get absoluteNumber => $composableBuilder(
    column: $table.absoluteNumber,
    builder: (column) => column,
  );

  GeneratedColumn<String> get posterSource => $composableBuilder(
    column: $table.posterSource,
    builder: (column) => column,
  );

  GeneratedColumn<String> get backdropSource => $composableBuilder(
    column: $table.backdropSource,
    builder: (column) => column,
  );

  GeneratedColumn<String> get logoSource => $composableBuilder(
    column: $table.logoSource,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tmdbId =>
      $composableBuilder(column: $table.tmdbId, builder: (column) => column);

  GeneratedColumn<String> get imdbId =>
      $composableBuilder(column: $table.imdbId, builder: (column) => column);

  GeneratedColumn<String> get tvdbId =>
      $composableBuilder(column: $table.tvdbId, builder: (column) => column);

  GeneratedColumn<String> get bangumiId =>
      $composableBuilder(column: $table.bangumiId, builder: (column) => column);

  GeneratedColumn<String> get doubanId =>
      $composableBuilder(column: $table.doubanId, builder: (column) => column);

  GeneratedColumn<String> get metadataSource => $composableBuilder(
    column: $table.metadataSource,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get locked =>
      $composableBuilder(column: $table.locked, builder: (column) => column);

  GeneratedColumn<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<int> get scrapedAt =>
      $composableBuilder(column: $table.scrapedAt, builder: (column) => column);

  $$LibraryItemsTableAnnotationComposer get parentId {
    final $$LibraryItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.parentId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryItemsTableAnnotationComposer get showId {
    final $$LibraryItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.showId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> libraryFilesRefs<T extends Object>(
    Expression<T> Function($$LibraryFilesTableAnnotationComposer a) f,
  ) {
    final $$LibraryFilesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryFiles,
      getReferencedColumn: (t) => t.itemId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryFilesTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> libraryUserStatesRefs<T extends Object>(
    Expression<T> Function($$LibraryUserStatesTableAnnotationComposer a) f,
  ) {
    final $$LibraryUserStatesTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.libraryUserStates,
          getReferencedColumn: (t) => t.itemId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$LibraryUserStatesTableAnnotationComposer(
                $db: $db,
                $table: $db.libraryUserStates,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> libraryItemGenresRefs<T extends Object>(
    Expression<T> Function($$LibraryItemGenresTableAnnotationComposer a) f,
  ) {
    final $$LibraryItemGenresTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.libraryItemGenres,
          getReferencedColumn: (t) => t.itemId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$LibraryItemGenresTableAnnotationComposer(
                $db: $db,
                $table: $db.libraryItemGenres,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }

  Expression<T> libraryCreditsRefs<T extends Object>(
    Expression<T> Function($$LibraryCreditsTableAnnotationComposer a) f,
  ) {
    final $$LibraryCreditsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryCredits,
      getReferencedColumn: (t) => t.itemId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryCreditsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryCredits,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }

  Expression<T> libraryListItemsRefs<T extends Object>(
    Expression<T> Function($$LibraryListItemsTableAnnotationComposer a) f,
  ) {
    final $$LibraryListItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryListItems,
      getReferencedColumn: (t) => t.itemId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryListItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryListItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LibraryItemsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryItemsTable,
          LibraryItemRow,
          $$LibraryItemsTableFilterComposer,
          $$LibraryItemsTableOrderingComposer,
          $$LibraryItemsTableAnnotationComposer,
          $$LibraryItemsTableCreateCompanionBuilder,
          $$LibraryItemsTableUpdateCompanionBuilder,
          (LibraryItemRow, $$LibraryItemsTableReferences),
          LibraryItemRow,
          PrefetchHooks Function({
            bool parentId,
            bool showId,
            bool libraryFilesRefs,
            bool libraryUserStatesRefs,
            bool libraryItemGenresRefs,
            bool libraryCreditsRefs,
            bool libraryListItemsRefs,
          })
        > {
  $$LibraryItemsTableTableManager(_$AppDatabase db, $LibraryItemsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> libraryType = const Value.absent(),
                Value<int?> parentId = const Value.absent(),
                Value<int?> showId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> sortTitle = const Value.absent(),
                Value<String?> originalTitle = const Value.absent(),
                Value<String?> aliases = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> releaseDate = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<String?> tagline = const Value.absent(),
                Value<String?> contentRating = const Value.absent(),
                Value<String?> studio = const Value.absent(),
                Value<double?> rating = const Value.absent(),
                Value<int?> runtimeMs = const Value.absent(),
                Value<int?> seasonNumber = const Value.absent(),
                Value<int?> episodeNumber = const Value.absent(),
                Value<int?> absoluteNumber = const Value.absent(),
                Value<String?> posterSource = const Value.absent(),
                Value<String?> backdropSource = const Value.absent(),
                Value<String?> logoSource = const Value.absent(),
                Value<String?> tmdbId = const Value.absent(),
                Value<String?> imdbId = const Value.absent(),
                Value<String?> tvdbId = const Value.absent(),
                Value<String?> bangumiId = const Value.absent(),
                Value<String?> doubanId = const Value.absent(),
                Value<String?> metadataSource = const Value.absent(),
                Value<bool> locked = const Value.absent(),
                Value<int> addedAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
                Value<int?> scrapedAt = const Value.absent(),
              }) => LibraryItemsCompanion(
                id: id,
                kind: kind,
                libraryType: libraryType,
                parentId: parentId,
                showId: showId,
                title: title,
                sortTitle: sortTitle,
                originalTitle: originalTitle,
                aliases: aliases,
                year: year,
                releaseDate: releaseDate,
                summary: summary,
                tagline: tagline,
                contentRating: contentRating,
                studio: studio,
                rating: rating,
                runtimeMs: runtimeMs,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                absoluteNumber: absoluteNumber,
                posterSource: posterSource,
                backdropSource: backdropSource,
                logoSource: logoSource,
                tmdbId: tmdbId,
                imdbId: imdbId,
                tvdbId: tvdbId,
                bangumiId: bangumiId,
                doubanId: doubanId,
                metadataSource: metadataSource,
                locked: locked,
                addedAt: addedAt,
                updatedAt: updatedAt,
                scrapedAt: scrapedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String kind,
                required String libraryType,
                Value<int?> parentId = const Value.absent(),
                Value<int?> showId = const Value.absent(),
                required String title,
                required String sortTitle,
                Value<String?> originalTitle = const Value.absent(),
                Value<String?> aliases = const Value.absent(),
                Value<int?> year = const Value.absent(),
                Value<String?> releaseDate = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<String?> tagline = const Value.absent(),
                Value<String?> contentRating = const Value.absent(),
                Value<String?> studio = const Value.absent(),
                Value<double?> rating = const Value.absent(),
                Value<int?> runtimeMs = const Value.absent(),
                Value<int?> seasonNumber = const Value.absent(),
                Value<int?> episodeNumber = const Value.absent(),
                Value<int?> absoluteNumber = const Value.absent(),
                Value<String?> posterSource = const Value.absent(),
                Value<String?> backdropSource = const Value.absent(),
                Value<String?> logoSource = const Value.absent(),
                Value<String?> tmdbId = const Value.absent(),
                Value<String?> imdbId = const Value.absent(),
                Value<String?> tvdbId = const Value.absent(),
                Value<String?> bangumiId = const Value.absent(),
                Value<String?> doubanId = const Value.absent(),
                Value<String?> metadataSource = const Value.absent(),
                Value<bool> locked = const Value.absent(),
                required int addedAt,
                required int updatedAt,
                Value<int?> scrapedAt = const Value.absent(),
              }) => LibraryItemsCompanion.insert(
                id: id,
                kind: kind,
                libraryType: libraryType,
                parentId: parentId,
                showId: showId,
                title: title,
                sortTitle: sortTitle,
                originalTitle: originalTitle,
                aliases: aliases,
                year: year,
                releaseDate: releaseDate,
                summary: summary,
                tagline: tagline,
                contentRating: contentRating,
                studio: studio,
                rating: rating,
                runtimeMs: runtimeMs,
                seasonNumber: seasonNumber,
                episodeNumber: episodeNumber,
                absoluteNumber: absoluteNumber,
                posterSource: posterSource,
                backdropSource: backdropSource,
                logoSource: logoSource,
                tmdbId: tmdbId,
                imdbId: imdbId,
                tvdbId: tvdbId,
                bangumiId: bangumiId,
                doubanId: doubanId,
                metadataSource: metadataSource,
                locked: locked,
                addedAt: addedAt,
                updatedAt: updatedAt,
                scrapedAt: scrapedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LibraryItemsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({
                parentId = false,
                showId = false,
                libraryFilesRefs = false,
                libraryUserStatesRefs = false,
                libraryItemGenresRefs = false,
                libraryCreditsRefs = false,
                libraryListItemsRefs = false,
              }) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [
                    if (libraryFilesRefs) db.libraryFiles,
                    if (libraryUserStatesRefs) db.libraryUserStates,
                    if (libraryItemGenresRefs) db.libraryItemGenres,
                    if (libraryCreditsRefs) db.libraryCredits,
                    if (libraryListItemsRefs) db.libraryListItems,
                  ],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (parentId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.parentId,
                                    referencedTable:
                                        $$LibraryItemsTableReferences
                                            ._parentIdTable(db),
                                    referencedColumn:
                                        $$LibraryItemsTableReferences
                                            ._parentIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (showId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.showId,
                                    referencedTable:
                                        $$LibraryItemsTableReferences
                                            ._showIdTable(db),
                                    referencedColumn:
                                        $$LibraryItemsTableReferences
                                            ._showIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [
                      if (libraryFilesRefs)
                        await $_getPrefetchedData<
                          LibraryItemRow,
                          $LibraryItemsTable,
                          LibraryFileRow
                        >(
                          currentTable: table,
                          referencedTable: $$LibraryItemsTableReferences
                              ._libraryFilesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LibraryItemsTableReferences(
                                db,
                                table,
                                p0,
                              ).libraryFilesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.itemId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (libraryUserStatesRefs)
                        await $_getPrefetchedData<
                          LibraryItemRow,
                          $LibraryItemsTable,
                          LibraryUserStateRow
                        >(
                          currentTable: table,
                          referencedTable: $$LibraryItemsTableReferences
                              ._libraryUserStatesRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LibraryItemsTableReferences(
                                db,
                                table,
                                p0,
                              ).libraryUserStatesRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.itemId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (libraryItemGenresRefs)
                        await $_getPrefetchedData<
                          LibraryItemRow,
                          $LibraryItemsTable,
                          LibraryItemGenreRow
                        >(
                          currentTable: table,
                          referencedTable: $$LibraryItemsTableReferences
                              ._libraryItemGenresRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LibraryItemsTableReferences(
                                db,
                                table,
                                p0,
                              ).libraryItemGenresRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.itemId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (libraryCreditsRefs)
                        await $_getPrefetchedData<
                          LibraryItemRow,
                          $LibraryItemsTable,
                          LibraryCreditRow
                        >(
                          currentTable: table,
                          referencedTable: $$LibraryItemsTableReferences
                              ._libraryCreditsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LibraryItemsTableReferences(
                                db,
                                table,
                                p0,
                              ).libraryCreditsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.itemId == item.id,
                              ),
                          typedResults: items,
                        ),
                      if (libraryListItemsRefs)
                        await $_getPrefetchedData<
                          LibraryItemRow,
                          $LibraryItemsTable,
                          LibraryListItemRow
                        >(
                          currentTable: table,
                          referencedTable: $$LibraryItemsTableReferences
                              ._libraryListItemsRefsTable(db),
                          managerFromTypedResult: (p0) =>
                              $$LibraryItemsTableReferences(
                                db,
                                table,
                                p0,
                              ).libraryListItemsRefs,
                          referencedItemsForCurrentItem:
                              (item, referencedItems) => referencedItems.where(
                                (e) => e.itemId == item.id,
                              ),
                          typedResults: items,
                        ),
                    ];
                  },
                );
              },
        ),
      );
}

typedef $$LibraryItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryItemsTable,
      LibraryItemRow,
      $$LibraryItemsTableFilterComposer,
      $$LibraryItemsTableOrderingComposer,
      $$LibraryItemsTableAnnotationComposer,
      $$LibraryItemsTableCreateCompanionBuilder,
      $$LibraryItemsTableUpdateCompanionBuilder,
      (LibraryItemRow, $$LibraryItemsTableReferences),
      LibraryItemRow,
      PrefetchHooks Function({
        bool parentId,
        bool showId,
        bool libraryFilesRefs,
        bool libraryUserStatesRefs,
        bool libraryItemGenresRefs,
        bool libraryCreditsRefs,
        bool libraryListItemsRefs,
      })
    >;
typedef $$LibraryFilesTableCreateCompanionBuilder =
    LibraryFilesCompanion Function({
      Value<int> id,
      required String mountId,
      required String path,
      Value<String?> remoteId,
      Value<int?> size,
      Value<int?> modifiedAt,
      required String role,
      Value<int?> itemId,
      Value<int?> ownerFileId,
      Value<String> matchState,
      Value<bool> matchLocked,
      Value<String?> parsed,
      Value<String?> versionLabel,
      Value<String?> language,
      Value<int?> durationMs,
      Value<String?> container,
      Value<String?> videoCodec,
      Value<int?> width,
      Value<int?> height,
      Value<String?> hdrFormat,
      Value<String?> streams,
      Value<int?> probedAt,
      Value<int> seenInScan,
      required int addedAt,
    });
typedef $$LibraryFilesTableUpdateCompanionBuilder =
    LibraryFilesCompanion Function({
      Value<int> id,
      Value<String> mountId,
      Value<String> path,
      Value<String?> remoteId,
      Value<int?> size,
      Value<int?> modifiedAt,
      Value<String> role,
      Value<int?> itemId,
      Value<int?> ownerFileId,
      Value<String> matchState,
      Value<bool> matchLocked,
      Value<String?> parsed,
      Value<String?> versionLabel,
      Value<String?> language,
      Value<int?> durationMs,
      Value<String?> container,
      Value<String?> videoCodec,
      Value<int?> width,
      Value<int?> height,
      Value<String?> hdrFormat,
      Value<String?> streams,
      Value<int?> probedAt,
      Value<int> seenInScan,
      Value<int> addedAt,
    });

final class $$LibraryFilesTableReferences
    extends BaseReferences<_$AppDatabase, $LibraryFilesTable, LibraryFileRow> {
  $$LibraryFilesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MountsTable _mountIdTable(_$AppDatabase db) =>
      db.mounts.createAlias('library_files__mount_id__mounts__id');

  $$MountsTableProcessedTableManager get mountId {
    final $_column = $_itemColumn<String>('mount_id')!;

    final manager = $$MountsTableTableManager(
      $_db,
      $_db.mounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_mountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $LibraryItemsTable _itemIdTable(_$AppDatabase db) =>
      db.libraryItems.createAlias('library_files__item_id__library_items__id');

  $$LibraryItemsTableProcessedTableManager? get itemId {
    final $_column = $_itemColumn<int>('item_id');
    if ($_column == null) return null;
    final manager = $$LibraryItemsTableTableManager(
      $_db,
      $_db.libraryItems,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_itemIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $LibraryFilesTable _ownerFileIdTable(_$AppDatabase db) => db
      .libraryFiles
      .createAlias('library_files__owner_file_id__library_files__id');

  $$LibraryFilesTableProcessedTableManager? get ownerFileId {
    final $_column = $_itemColumn<int>('owner_file_id');
    if ($_column == null) return null;
    final manager = $$LibraryFilesTableTableManager(
      $_db,
      $_db.libraryFiles,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_ownerFileIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LibraryFilesTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryFilesTable> {
  $$LibraryFilesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get modifiedAt => $composableBuilder(
    column: $table.modifiedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get matchState => $composableBuilder(
    column: $table.matchState,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get matchLocked => $composableBuilder(
    column: $table.matchLocked,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get parsed => $composableBuilder(
    column: $table.parsed,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get versionLabel => $composableBuilder(
    column: $table.versionLabel,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get language => $composableBuilder(
    column: $table.language,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get container => $composableBuilder(
    column: $table.container,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get videoCodec => $composableBuilder(
    column: $table.videoCodec,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get hdrFormat => $composableBuilder(
    column: $table.hdrFormat,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get streams => $composableBuilder(
    column: $table.streams,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get probedAt => $composableBuilder(
    column: $table.probedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get seenInScan => $composableBuilder(
    column: $table.seenInScan,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$MountsTableFilterComposer get mountId {
    final $$MountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.mountId,
      referencedTable: $db.mounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MountsTableFilterComposer(
            $db: $db,
            $table: $db.mounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryItemsTableFilterComposer get itemId {
    final $$LibraryItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableFilterComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryFilesTableFilterComposer get ownerFileId {
    final $$LibraryFilesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.ownerFileId,
      referencedTable: $db.libraryFiles,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryFilesTableFilterComposer(
            $db: $db,
            $table: $db.libraryFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryFilesTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryFilesTable> {
  $$LibraryFilesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get path => $composableBuilder(
    column: $table.path,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get remoteId => $composableBuilder(
    column: $table.remoteId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get size => $composableBuilder(
    column: $table.size,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get modifiedAt => $composableBuilder(
    column: $table.modifiedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get matchState => $composableBuilder(
    column: $table.matchState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get matchLocked => $composableBuilder(
    column: $table.matchLocked,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get parsed => $composableBuilder(
    column: $table.parsed,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get versionLabel => $composableBuilder(
    column: $table.versionLabel,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get language => $composableBuilder(
    column: $table.language,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get container => $composableBuilder(
    column: $table.container,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get videoCodec => $composableBuilder(
    column: $table.videoCodec,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get width => $composableBuilder(
    column: $table.width,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get height => $composableBuilder(
    column: $table.height,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get hdrFormat => $composableBuilder(
    column: $table.hdrFormat,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get streams => $composableBuilder(
    column: $table.streams,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get probedAt => $composableBuilder(
    column: $table.probedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get seenInScan => $composableBuilder(
    column: $table.seenInScan,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$MountsTableOrderingComposer get mountId {
    final $$MountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.mountId,
      referencedTable: $db.mounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MountsTableOrderingComposer(
            $db: $db,
            $table: $db.mounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryItemsTableOrderingComposer get itemId {
    final $$LibraryItemsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableOrderingComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryFilesTableOrderingComposer get ownerFileId {
    final $$LibraryFilesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.ownerFileId,
      referencedTable: $db.libraryFiles,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryFilesTableOrderingComposer(
            $db: $db,
            $table: $db.libraryFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryFilesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryFilesTable> {
  $$LibraryFilesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get path =>
      $composableBuilder(column: $table.path, builder: (column) => column);

  GeneratedColumn<String> get remoteId =>
      $composableBuilder(column: $table.remoteId, builder: (column) => column);

  GeneratedColumn<int> get size =>
      $composableBuilder(column: $table.size, builder: (column) => column);

  GeneratedColumn<int> get modifiedAt => $composableBuilder(
    column: $table.modifiedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get matchState => $composableBuilder(
    column: $table.matchState,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get matchLocked => $composableBuilder(
    column: $table.matchLocked,
    builder: (column) => column,
  );

  GeneratedColumn<String> get parsed =>
      $composableBuilder(column: $table.parsed, builder: (column) => column);

  GeneratedColumn<String> get versionLabel => $composableBuilder(
    column: $table.versionLabel,
    builder: (column) => column,
  );

  GeneratedColumn<String> get language =>
      $composableBuilder(column: $table.language, builder: (column) => column);

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<String> get container =>
      $composableBuilder(column: $table.container, builder: (column) => column);

  GeneratedColumn<String> get videoCodec => $composableBuilder(
    column: $table.videoCodec,
    builder: (column) => column,
  );

  GeneratedColumn<int> get width =>
      $composableBuilder(column: $table.width, builder: (column) => column);

  GeneratedColumn<int> get height =>
      $composableBuilder(column: $table.height, builder: (column) => column);

  GeneratedColumn<String> get hdrFormat =>
      $composableBuilder(column: $table.hdrFormat, builder: (column) => column);

  GeneratedColumn<String> get streams =>
      $composableBuilder(column: $table.streams, builder: (column) => column);

  GeneratedColumn<int> get probedAt =>
      $composableBuilder(column: $table.probedAt, builder: (column) => column);

  GeneratedColumn<int> get seenInScan => $composableBuilder(
    column: $table.seenInScan,
    builder: (column) => column,
  );

  GeneratedColumn<int> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);

  $$MountsTableAnnotationComposer get mountId {
    final $$MountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.mountId,
      referencedTable: $db.mounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MountsTableAnnotationComposer(
            $db: $db,
            $table: $db.mounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryItemsTableAnnotationComposer get itemId {
    final $$LibraryItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryFilesTableAnnotationComposer get ownerFileId {
    final $$LibraryFilesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.ownerFileId,
      referencedTable: $db.libraryFiles,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryFilesTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryFiles,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryFilesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryFilesTable,
          LibraryFileRow,
          $$LibraryFilesTableFilterComposer,
          $$LibraryFilesTableOrderingComposer,
          $$LibraryFilesTableAnnotationComposer,
          $$LibraryFilesTableCreateCompanionBuilder,
          $$LibraryFilesTableUpdateCompanionBuilder,
          (LibraryFileRow, $$LibraryFilesTableReferences),
          LibraryFileRow,
          PrefetchHooks Function({bool mountId, bool itemId, bool ownerFileId})
        > {
  $$LibraryFilesTableTableManager(_$AppDatabase db, $LibraryFilesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryFilesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryFilesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryFilesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> mountId = const Value.absent(),
                Value<String> path = const Value.absent(),
                Value<String?> remoteId = const Value.absent(),
                Value<int?> size = const Value.absent(),
                Value<int?> modifiedAt = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<int?> itemId = const Value.absent(),
                Value<int?> ownerFileId = const Value.absent(),
                Value<String> matchState = const Value.absent(),
                Value<bool> matchLocked = const Value.absent(),
                Value<String?> parsed = const Value.absent(),
                Value<String?> versionLabel = const Value.absent(),
                Value<String?> language = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> container = const Value.absent(),
                Value<String?> videoCodec = const Value.absent(),
                Value<int?> width = const Value.absent(),
                Value<int?> height = const Value.absent(),
                Value<String?> hdrFormat = const Value.absent(),
                Value<String?> streams = const Value.absent(),
                Value<int?> probedAt = const Value.absent(),
                Value<int> seenInScan = const Value.absent(),
                Value<int> addedAt = const Value.absent(),
              }) => LibraryFilesCompanion(
                id: id,
                mountId: mountId,
                path: path,
                remoteId: remoteId,
                size: size,
                modifiedAt: modifiedAt,
                role: role,
                itemId: itemId,
                ownerFileId: ownerFileId,
                matchState: matchState,
                matchLocked: matchLocked,
                parsed: parsed,
                versionLabel: versionLabel,
                language: language,
                durationMs: durationMs,
                container: container,
                videoCodec: videoCodec,
                width: width,
                height: height,
                hdrFormat: hdrFormat,
                streams: streams,
                probedAt: probedAt,
                seenInScan: seenInScan,
                addedAt: addedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String mountId,
                required String path,
                Value<String?> remoteId = const Value.absent(),
                Value<int?> size = const Value.absent(),
                Value<int?> modifiedAt = const Value.absent(),
                required String role,
                Value<int?> itemId = const Value.absent(),
                Value<int?> ownerFileId = const Value.absent(),
                Value<String> matchState = const Value.absent(),
                Value<bool> matchLocked = const Value.absent(),
                Value<String?> parsed = const Value.absent(),
                Value<String?> versionLabel = const Value.absent(),
                Value<String?> language = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<String?> container = const Value.absent(),
                Value<String?> videoCodec = const Value.absent(),
                Value<int?> width = const Value.absent(),
                Value<int?> height = const Value.absent(),
                Value<String?> hdrFormat = const Value.absent(),
                Value<String?> streams = const Value.absent(),
                Value<int?> probedAt = const Value.absent(),
                Value<int> seenInScan = const Value.absent(),
                required int addedAt,
              }) => LibraryFilesCompanion.insert(
                id: id,
                mountId: mountId,
                path: path,
                remoteId: remoteId,
                size: size,
                modifiedAt: modifiedAt,
                role: role,
                itemId: itemId,
                ownerFileId: ownerFileId,
                matchState: matchState,
                matchLocked: matchLocked,
                parsed: parsed,
                versionLabel: versionLabel,
                language: language,
                durationMs: durationMs,
                container: container,
                videoCodec: videoCodec,
                width: width,
                height: height,
                hdrFormat: hdrFormat,
                streams: streams,
                probedAt: probedAt,
                seenInScan: seenInScan,
                addedAt: addedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LibraryFilesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback:
              ({mountId = false, itemId = false, ownerFileId = false}) {
                return PrefetchHooks(
                  db: db,
                  explicitlyWatchedTables: [],
                  addJoins:
                      <
                        T extends TableManagerState<
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic,
                          dynamic
                        >
                      >(state) {
                        if (mountId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.mountId,
                                    referencedTable:
                                        $$LibraryFilesTableReferences
                                            ._mountIdTable(db),
                                    referencedColumn:
                                        $$LibraryFilesTableReferences
                                            ._mountIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (itemId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.itemId,
                                    referencedTable:
                                        $$LibraryFilesTableReferences
                                            ._itemIdTable(db),
                                    referencedColumn:
                                        $$LibraryFilesTableReferences
                                            ._itemIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }
                        if (ownerFileId) {
                          state =
                              state.withJoin(
                                    currentTable: table,
                                    currentColumn: table.ownerFileId,
                                    referencedTable:
                                        $$LibraryFilesTableReferences
                                            ._ownerFileIdTable(db),
                                    referencedColumn:
                                        $$LibraryFilesTableReferences
                                            ._ownerFileIdTable(db)
                                            .id,
                                  )
                                  as T;
                        }

                        return state;
                      },
                  getPrefetchedDataCallback: (items) async {
                    return [];
                  },
                );
              },
        ),
      );
}

typedef $$LibraryFilesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryFilesTable,
      LibraryFileRow,
      $$LibraryFilesTableFilterComposer,
      $$LibraryFilesTableOrderingComposer,
      $$LibraryFilesTableAnnotationComposer,
      $$LibraryFilesTableCreateCompanionBuilder,
      $$LibraryFilesTableUpdateCompanionBuilder,
      (LibraryFileRow, $$LibraryFilesTableReferences),
      LibraryFileRow,
      PrefetchHooks Function({bool mountId, bool itemId, bool ownerFileId})
    >;
typedef $$LibraryUserStatesTableCreateCompanionBuilder =
    LibraryUserStatesCompanion Function({
      Value<int> itemId,
      Value<int> positionMs,
      Value<int?> durationMs,
      Value<bool> watched,
      Value<int> playCount,
      Value<int?> lastPlayedAt,
      Value<bool> favorite,
      Value<bool> hiddenFromContinue,
      required int updatedAt,
    });
typedef $$LibraryUserStatesTableUpdateCompanionBuilder =
    LibraryUserStatesCompanion Function({
      Value<int> itemId,
      Value<int> positionMs,
      Value<int?> durationMs,
      Value<bool> watched,
      Value<int> playCount,
      Value<int?> lastPlayedAt,
      Value<bool> favorite,
      Value<bool> hiddenFromContinue,
      Value<int> updatedAt,
    });

final class $$LibraryUserStatesTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $LibraryUserStatesTable,
          LibraryUserStateRow
        > {
  $$LibraryUserStatesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LibraryItemsTable _itemIdTable(_$AppDatabase db) => db.libraryItems
      .createAlias('library_user_states__item_id__library_items__id');

  $$LibraryItemsTableProcessedTableManager get itemId {
    final $_column = $_itemColumn<int>('item_id')!;

    final manager = $$LibraryItemsTableTableManager(
      $_db,
      $_db.libraryItems,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_itemIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LibraryUserStatesTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryUserStatesTable> {
  $$LibraryUserStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get watched => $composableBuilder(
    column: $table.watched,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get playCount => $composableBuilder(
    column: $table.playCount,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get favorite => $composableBuilder(
    column: $table.favorite,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get hiddenFromContinue => $composableBuilder(
    column: $table.hiddenFromContinue,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  $$LibraryItemsTableFilterComposer get itemId {
    final $$LibraryItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableFilterComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryUserStatesTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryUserStatesTable> {
  $$LibraryUserStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get watched => $composableBuilder(
    column: $table.watched,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get playCount => $composableBuilder(
    column: $table.playCount,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get favorite => $composableBuilder(
    column: $table.favorite,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get hiddenFromContinue => $composableBuilder(
    column: $table.hiddenFromContinue,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  $$LibraryItemsTableOrderingComposer get itemId {
    final $$LibraryItemsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableOrderingComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryUserStatesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryUserStatesTable> {
  $$LibraryUserStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get positionMs => $composableBuilder(
    column: $table.positionMs,
    builder: (column) => column,
  );

  GeneratedColumn<int> get durationMs => $composableBuilder(
    column: $table.durationMs,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get watched =>
      $composableBuilder(column: $table.watched, builder: (column) => column);

  GeneratedColumn<int> get playCount =>
      $composableBuilder(column: $table.playCount, builder: (column) => column);

  GeneratedColumn<int> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get favorite =>
      $composableBuilder(column: $table.favorite, builder: (column) => column);

  GeneratedColumn<bool> get hiddenFromContinue => $composableBuilder(
    column: $table.hiddenFromContinue,
    builder: (column) => column,
  );

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  $$LibraryItemsTableAnnotationComposer get itemId {
    final $$LibraryItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryUserStatesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryUserStatesTable,
          LibraryUserStateRow,
          $$LibraryUserStatesTableFilterComposer,
          $$LibraryUserStatesTableOrderingComposer,
          $$LibraryUserStatesTableAnnotationComposer,
          $$LibraryUserStatesTableCreateCompanionBuilder,
          $$LibraryUserStatesTableUpdateCompanionBuilder,
          (LibraryUserStateRow, $$LibraryUserStatesTableReferences),
          LibraryUserStateRow,
          PrefetchHooks Function({bool itemId})
        > {
  $$LibraryUserStatesTableTableManager(
    _$AppDatabase db,
    $LibraryUserStatesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryUserStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryUserStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryUserStatesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> itemId = const Value.absent(),
                Value<int> positionMs = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<bool> watched = const Value.absent(),
                Value<int> playCount = const Value.absent(),
                Value<int?> lastPlayedAt = const Value.absent(),
                Value<bool> favorite = const Value.absent(),
                Value<bool> hiddenFromContinue = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
              }) => LibraryUserStatesCompanion(
                itemId: itemId,
                positionMs: positionMs,
                durationMs: durationMs,
                watched: watched,
                playCount: playCount,
                lastPlayedAt: lastPlayedAt,
                favorite: favorite,
                hiddenFromContinue: hiddenFromContinue,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> itemId = const Value.absent(),
                Value<int> positionMs = const Value.absent(),
                Value<int?> durationMs = const Value.absent(),
                Value<bool> watched = const Value.absent(),
                Value<int> playCount = const Value.absent(),
                Value<int?> lastPlayedAt = const Value.absent(),
                Value<bool> favorite = const Value.absent(),
                Value<bool> hiddenFromContinue = const Value.absent(),
                required int updatedAt,
              }) => LibraryUserStatesCompanion.insert(
                itemId: itemId,
                positionMs: positionMs,
                durationMs: durationMs,
                watched: watched,
                playCount: playCount,
                lastPlayedAt: lastPlayedAt,
                favorite: favorite,
                hiddenFromContinue: hiddenFromContinue,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LibraryUserStatesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({itemId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (itemId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.itemId,
                                referencedTable:
                                    $$LibraryUserStatesTableReferences
                                        ._itemIdTable(db),
                                referencedColumn:
                                    $$LibraryUserStatesTableReferences
                                        ._itemIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$LibraryUserStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryUserStatesTable,
      LibraryUserStateRow,
      $$LibraryUserStatesTableFilterComposer,
      $$LibraryUserStatesTableOrderingComposer,
      $$LibraryUserStatesTableAnnotationComposer,
      $$LibraryUserStatesTableCreateCompanionBuilder,
      $$LibraryUserStatesTableUpdateCompanionBuilder,
      (LibraryUserStateRow, $$LibraryUserStatesTableReferences),
      LibraryUserStateRow,
      PrefetchHooks Function({bool itemId})
    >;
typedef $$LibraryGenresTableCreateCompanionBuilder =
    LibraryGenresCompanion Function({Value<int> id, required String name});
typedef $$LibraryGenresTableUpdateCompanionBuilder =
    LibraryGenresCompanion Function({Value<int> id, Value<String> name});

final class $$LibraryGenresTableReferences
    extends
        BaseReferences<_$AppDatabase, $LibraryGenresTable, LibraryGenreRow> {
  $$LibraryGenresTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$LibraryItemGenresTable, List<LibraryItemGenreRow>>
  _libraryItemGenresRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(
        db.libraryItemGenres,
        aliasName: 'library_genres__id__library_item_genres__genre_id',
      );

  $$LibraryItemGenresTableProcessedTableManager get libraryItemGenresRefs {
    final manager = $$LibraryItemGenresTableTableManager(
      $_db,
      $_db.libraryItemGenres,
    ).filter((f) => f.genreId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _libraryItemGenresRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$LibraryGenresTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryGenresTable> {
  $$LibraryGenresTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> libraryItemGenresRefs(
    Expression<bool> Function($$LibraryItemGenresTableFilterComposer f) f,
  ) {
    final $$LibraryItemGenresTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryItemGenres,
      getReferencedColumn: (t) => t.genreId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemGenresTableFilterComposer(
            $db: $db,
            $table: $db.libraryItemGenres,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LibraryGenresTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryGenresTable> {
  $$LibraryGenresTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LibraryGenresTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryGenresTable> {
  $$LibraryGenresTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  Expression<T> libraryItemGenresRefs<T extends Object>(
    Expression<T> Function($$LibraryItemGenresTableAnnotationComposer a) f,
  ) {
    final $$LibraryItemGenresTableAnnotationComposer composer =
        $composerBuilder(
          composer: this,
          getCurrentColumn: (t) => t.id,
          referencedTable: $db.libraryItemGenres,
          getReferencedColumn: (t) => t.genreId,
          builder:
              (
                joinBuilder, {
                $addJoinBuilderToRootComposer,
                $removeJoinBuilderFromRootComposer,
              }) => $$LibraryItemGenresTableAnnotationComposer(
                $db: $db,
                $table: $db.libraryItemGenres,
                $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
                joinBuilder: joinBuilder,
                $removeJoinBuilderFromRootComposer:
                    $removeJoinBuilderFromRootComposer,
              ),
        );
    return f(composer);
  }
}

class $$LibraryGenresTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryGenresTable,
          LibraryGenreRow,
          $$LibraryGenresTableFilterComposer,
          $$LibraryGenresTableOrderingComposer,
          $$LibraryGenresTableAnnotationComposer,
          $$LibraryGenresTableCreateCompanionBuilder,
          $$LibraryGenresTableUpdateCompanionBuilder,
          (LibraryGenreRow, $$LibraryGenresTableReferences),
          LibraryGenreRow,
          PrefetchHooks Function({bool libraryItemGenresRefs})
        > {
  $$LibraryGenresTableTableManager(_$AppDatabase db, $LibraryGenresTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryGenresTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryGenresTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryGenresTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
              }) => LibraryGenresCompanion(id: id, name: name),
          createCompanionCallback:
              ({Value<int> id = const Value.absent(), required String name}) =>
                  LibraryGenresCompanion.insert(id: id, name: name),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LibraryGenresTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({libraryItemGenresRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (libraryItemGenresRefs) db.libraryItemGenres,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (libraryItemGenresRefs)
                    await $_getPrefetchedData<
                      LibraryGenreRow,
                      $LibraryGenresTable,
                      LibraryItemGenreRow
                    >(
                      currentTable: table,
                      referencedTable: $$LibraryGenresTableReferences
                          ._libraryItemGenresRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$LibraryGenresTableReferences(
                            db,
                            table,
                            p0,
                          ).libraryItemGenresRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.genreId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$LibraryGenresTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryGenresTable,
      LibraryGenreRow,
      $$LibraryGenresTableFilterComposer,
      $$LibraryGenresTableOrderingComposer,
      $$LibraryGenresTableAnnotationComposer,
      $$LibraryGenresTableCreateCompanionBuilder,
      $$LibraryGenresTableUpdateCompanionBuilder,
      (LibraryGenreRow, $$LibraryGenresTableReferences),
      LibraryGenreRow,
      PrefetchHooks Function({bool libraryItemGenresRefs})
    >;
typedef $$LibraryItemGenresTableCreateCompanionBuilder =
    LibraryItemGenresCompanion Function({
      required int itemId,
      required int genreId,
      Value<int> rowid,
    });
typedef $$LibraryItemGenresTableUpdateCompanionBuilder =
    LibraryItemGenresCompanion Function({
      Value<int> itemId,
      Value<int> genreId,
      Value<int> rowid,
    });

final class $$LibraryItemGenresTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $LibraryItemGenresTable,
          LibraryItemGenreRow
        > {
  $$LibraryItemGenresTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LibraryItemsTable _itemIdTable(_$AppDatabase db) => db.libraryItems
      .createAlias('library_item_genres__item_id__library_items__id');

  $$LibraryItemsTableProcessedTableManager get itemId {
    final $_column = $_itemColumn<int>('item_id')!;

    final manager = $$LibraryItemsTableTableManager(
      $_db,
      $_db.libraryItems,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_itemIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $LibraryGenresTable _genreIdTable(_$AppDatabase db) => db.libraryGenres
      .createAlias('library_item_genres__genre_id__library_genres__id');

  $$LibraryGenresTableProcessedTableManager get genreId {
    final $_column = $_itemColumn<int>('genre_id')!;

    final manager = $$LibraryGenresTableTableManager(
      $_db,
      $_db.libraryGenres,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_genreIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LibraryItemGenresTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryItemGenresTable> {
  $$LibraryItemGenresTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  $$LibraryItemsTableFilterComposer get itemId {
    final $$LibraryItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableFilterComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryGenresTableFilterComposer get genreId {
    final $$LibraryGenresTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.genreId,
      referencedTable: $db.libraryGenres,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryGenresTableFilterComposer(
            $db: $db,
            $table: $db.libraryGenres,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryItemGenresTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryItemGenresTable> {
  $$LibraryItemGenresTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  $$LibraryItemsTableOrderingComposer get itemId {
    final $$LibraryItemsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableOrderingComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryGenresTableOrderingComposer get genreId {
    final $$LibraryGenresTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.genreId,
      referencedTable: $db.libraryGenres,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryGenresTableOrderingComposer(
            $db: $db,
            $table: $db.libraryGenres,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryItemGenresTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryItemGenresTable> {
  $$LibraryItemGenresTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  $$LibraryItemsTableAnnotationComposer get itemId {
    final $$LibraryItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryGenresTableAnnotationComposer get genreId {
    final $$LibraryGenresTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.genreId,
      referencedTable: $db.libraryGenres,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryGenresTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryGenres,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryItemGenresTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryItemGenresTable,
          LibraryItemGenreRow,
          $$LibraryItemGenresTableFilterComposer,
          $$LibraryItemGenresTableOrderingComposer,
          $$LibraryItemGenresTableAnnotationComposer,
          $$LibraryItemGenresTableCreateCompanionBuilder,
          $$LibraryItemGenresTableUpdateCompanionBuilder,
          (LibraryItemGenreRow, $$LibraryItemGenresTableReferences),
          LibraryItemGenreRow,
          PrefetchHooks Function({bool itemId, bool genreId})
        > {
  $$LibraryItemGenresTableTableManager(
    _$AppDatabase db,
    $LibraryItemGenresTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryItemGenresTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryItemGenresTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryItemGenresTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<int> itemId = const Value.absent(),
                Value<int> genreId = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryItemGenresCompanion(
                itemId: itemId,
                genreId: genreId,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int itemId,
                required int genreId,
                Value<int> rowid = const Value.absent(),
              }) => LibraryItemGenresCompanion.insert(
                itemId: itemId,
                genreId: genreId,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LibraryItemGenresTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({itemId = false, genreId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (itemId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.itemId,
                                referencedTable:
                                    $$LibraryItemGenresTableReferences
                                        ._itemIdTable(db),
                                referencedColumn:
                                    $$LibraryItemGenresTableReferences
                                        ._itemIdTable(db)
                                        .id,
                              )
                              as T;
                    }
                    if (genreId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.genreId,
                                referencedTable:
                                    $$LibraryItemGenresTableReferences
                                        ._genreIdTable(db),
                                referencedColumn:
                                    $$LibraryItemGenresTableReferences
                                        ._genreIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$LibraryItemGenresTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryItemGenresTable,
      LibraryItemGenreRow,
      $$LibraryItemGenresTableFilterComposer,
      $$LibraryItemGenresTableOrderingComposer,
      $$LibraryItemGenresTableAnnotationComposer,
      $$LibraryItemGenresTableCreateCompanionBuilder,
      $$LibraryItemGenresTableUpdateCompanionBuilder,
      (LibraryItemGenreRow, $$LibraryItemGenresTableReferences),
      LibraryItemGenreRow,
      PrefetchHooks Function({bool itemId, bool genreId})
    >;
typedef $$LibraryPeopleTableCreateCompanionBuilder =
    LibraryPeopleCompanion Function({
      Value<int> id,
      required String name,
      Value<String?> tmdbId,
      Value<String?> photoSource,
    });
typedef $$LibraryPeopleTableUpdateCompanionBuilder =
    LibraryPeopleCompanion Function({
      Value<int> id,
      Value<String> name,
      Value<String?> tmdbId,
      Value<String?> photoSource,
    });

final class $$LibraryPeopleTableReferences
    extends
        BaseReferences<_$AppDatabase, $LibraryPeopleTable, LibraryPersonRow> {
  $$LibraryPeopleTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static MultiTypedResultKey<$LibraryCreditsTable, List<LibraryCreditRow>>
  _libraryCreditsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.libraryCredits,
    aliasName: 'library_people__id__library_credits__person_id',
  );

  $$LibraryCreditsTableProcessedTableManager get libraryCreditsRefs {
    final manager = $$LibraryCreditsTableTableManager(
      $_db,
      $_db.libraryCredits,
    ).filter((f) => f.personId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(_libraryCreditsRefsTable($_db));
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$LibraryPeopleTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryPeopleTable> {
  $$LibraryPeopleTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get photoSource => $composableBuilder(
    column: $table.photoSource,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> libraryCreditsRefs(
    Expression<bool> Function($$LibraryCreditsTableFilterComposer f) f,
  ) {
    final $$LibraryCreditsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryCredits,
      getReferencedColumn: (t) => t.personId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryCreditsTableFilterComposer(
            $db: $db,
            $table: $db.libraryCredits,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LibraryPeopleTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryPeopleTable> {
  $$LibraryPeopleTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get photoSource => $composableBuilder(
    column: $table.photoSource,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LibraryPeopleTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryPeopleTable> {
  $$LibraryPeopleTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get tmdbId =>
      $composableBuilder(column: $table.tmdbId, builder: (column) => column);

  GeneratedColumn<String> get photoSource => $composableBuilder(
    column: $table.photoSource,
    builder: (column) => column,
  );

  Expression<T> libraryCreditsRefs<T extends Object>(
    Expression<T> Function($$LibraryCreditsTableAnnotationComposer a) f,
  ) {
    final $$LibraryCreditsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryCredits,
      getReferencedColumn: (t) => t.personId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryCreditsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryCredits,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LibraryPeopleTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryPeopleTable,
          LibraryPersonRow,
          $$LibraryPeopleTableFilterComposer,
          $$LibraryPeopleTableOrderingComposer,
          $$LibraryPeopleTableAnnotationComposer,
          $$LibraryPeopleTableCreateCompanionBuilder,
          $$LibraryPeopleTableUpdateCompanionBuilder,
          (LibraryPersonRow, $$LibraryPeopleTableReferences),
          LibraryPersonRow,
          PrefetchHooks Function({bool libraryCreditsRefs})
        > {
  $$LibraryPeopleTableTableManager(_$AppDatabase db, $LibraryPeopleTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryPeopleTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryPeopleTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryPeopleTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> tmdbId = const Value.absent(),
                Value<String?> photoSource = const Value.absent(),
              }) => LibraryPeopleCompanion(
                id: id,
                name: name,
                tmdbId: tmdbId,
                photoSource: photoSource,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String name,
                Value<String?> tmdbId = const Value.absent(),
                Value<String?> photoSource = const Value.absent(),
              }) => LibraryPeopleCompanion.insert(
                id: id,
                name: name,
                tmdbId: tmdbId,
                photoSource: photoSource,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LibraryPeopleTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({libraryCreditsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (libraryCreditsRefs) db.libraryCredits,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (libraryCreditsRefs)
                    await $_getPrefetchedData<
                      LibraryPersonRow,
                      $LibraryPeopleTable,
                      LibraryCreditRow
                    >(
                      currentTable: table,
                      referencedTable: $$LibraryPeopleTableReferences
                          ._libraryCreditsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$LibraryPeopleTableReferences(
                            db,
                            table,
                            p0,
                          ).libraryCreditsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.personId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$LibraryPeopleTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryPeopleTable,
      LibraryPersonRow,
      $$LibraryPeopleTableFilterComposer,
      $$LibraryPeopleTableOrderingComposer,
      $$LibraryPeopleTableAnnotationComposer,
      $$LibraryPeopleTableCreateCompanionBuilder,
      $$LibraryPeopleTableUpdateCompanionBuilder,
      (LibraryPersonRow, $$LibraryPeopleTableReferences),
      LibraryPersonRow,
      PrefetchHooks Function({bool libraryCreditsRefs})
    >;
typedef $$LibraryCreditsTableCreateCompanionBuilder =
    LibraryCreditsCompanion Function({
      required int itemId,
      required int personId,
      required String job,
      Value<String?> character,
      Value<int> sortOrder,
      Value<int> rowid,
    });
typedef $$LibraryCreditsTableUpdateCompanionBuilder =
    LibraryCreditsCompanion Function({
      Value<int> itemId,
      Value<int> personId,
      Value<String> job,
      Value<String?> character,
      Value<int> sortOrder,
      Value<int> rowid,
    });

final class $$LibraryCreditsTableReferences
    extends
        BaseReferences<_$AppDatabase, $LibraryCreditsTable, LibraryCreditRow> {
  $$LibraryCreditsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LibraryItemsTable _itemIdTable(_$AppDatabase db) => db.libraryItems
      .createAlias('library_credits__item_id__library_items__id');

  $$LibraryItemsTableProcessedTableManager get itemId {
    final $_column = $_itemColumn<int>('item_id')!;

    final manager = $$LibraryItemsTableTableManager(
      $_db,
      $_db.libraryItems,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_itemIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $LibraryPeopleTable _personIdTable(_$AppDatabase db) => db
      .libraryPeople
      .createAlias('library_credits__person_id__library_people__id');

  $$LibraryPeopleTableProcessedTableManager get personId {
    final $_column = $_itemColumn<int>('person_id')!;

    final manager = $$LibraryPeopleTableTableManager(
      $_db,
      $_db.libraryPeople,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_personIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LibraryCreditsTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryCreditsTable> {
  $$LibraryCreditsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get job => $composableBuilder(
    column: $table.job,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get character => $composableBuilder(
    column: $table.character,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  $$LibraryItemsTableFilterComposer get itemId {
    final $$LibraryItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableFilterComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryPeopleTableFilterComposer get personId {
    final $$LibraryPeopleTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.personId,
      referencedTable: $db.libraryPeople,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryPeopleTableFilterComposer(
            $db: $db,
            $table: $db.libraryPeople,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryCreditsTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryCreditsTable> {
  $$LibraryCreditsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get job => $composableBuilder(
    column: $table.job,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get character => $composableBuilder(
    column: $table.character,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  $$LibraryItemsTableOrderingComposer get itemId {
    final $$LibraryItemsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableOrderingComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryPeopleTableOrderingComposer get personId {
    final $$LibraryPeopleTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.personId,
      referencedTable: $db.libraryPeople,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryPeopleTableOrderingComposer(
            $db: $db,
            $table: $db.libraryPeople,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryCreditsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryCreditsTable> {
  $$LibraryCreditsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get job =>
      $composableBuilder(column: $table.job, builder: (column) => column);

  GeneratedColumn<String> get character =>
      $composableBuilder(column: $table.character, builder: (column) => column);

  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  $$LibraryItemsTableAnnotationComposer get itemId {
    final $$LibraryItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryPeopleTableAnnotationComposer get personId {
    final $$LibraryPeopleTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.personId,
      referencedTable: $db.libraryPeople,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryPeopleTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryPeople,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryCreditsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryCreditsTable,
          LibraryCreditRow,
          $$LibraryCreditsTableFilterComposer,
          $$LibraryCreditsTableOrderingComposer,
          $$LibraryCreditsTableAnnotationComposer,
          $$LibraryCreditsTableCreateCompanionBuilder,
          $$LibraryCreditsTableUpdateCompanionBuilder,
          (LibraryCreditRow, $$LibraryCreditsTableReferences),
          LibraryCreditRow,
          PrefetchHooks Function({bool itemId, bool personId})
        > {
  $$LibraryCreditsTableTableManager(
    _$AppDatabase db,
    $LibraryCreditsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryCreditsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryCreditsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryCreditsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> itemId = const Value.absent(),
                Value<int> personId = const Value.absent(),
                Value<String> job = const Value.absent(),
                Value<String?> character = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryCreditsCompanion(
                itemId: itemId,
                personId: personId,
                job: job,
                character: character,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int itemId,
                required int personId,
                required String job,
                Value<String?> character = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryCreditsCompanion.insert(
                itemId: itemId,
                personId: personId,
                job: job,
                character: character,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LibraryCreditsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({itemId = false, personId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (itemId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.itemId,
                                referencedTable: $$LibraryCreditsTableReferences
                                    ._itemIdTable(db),
                                referencedColumn:
                                    $$LibraryCreditsTableReferences
                                        ._itemIdTable(db)
                                        .id,
                              )
                              as T;
                    }
                    if (personId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.personId,
                                referencedTable: $$LibraryCreditsTableReferences
                                    ._personIdTable(db),
                                referencedColumn:
                                    $$LibraryCreditsTableReferences
                                        ._personIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$LibraryCreditsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryCreditsTable,
      LibraryCreditRow,
      $$LibraryCreditsTableFilterComposer,
      $$LibraryCreditsTableOrderingComposer,
      $$LibraryCreditsTableAnnotationComposer,
      $$LibraryCreditsTableCreateCompanionBuilder,
      $$LibraryCreditsTableUpdateCompanionBuilder,
      (LibraryCreditRow, $$LibraryCreditsTableReferences),
      LibraryCreditRow,
      PrefetchHooks Function({bool itemId, bool personId})
    >;
typedef $$LibraryListsTableCreateCompanionBuilder =
    LibraryListsCompanion Function({
      Value<int> id,
      required String kind,
      required String title,
      Value<String?> summary,
      Value<String?> posterSource,
      Value<String?> tmdbId,
      required int createdAt,
      required int updatedAt,
    });
typedef $$LibraryListsTableUpdateCompanionBuilder =
    LibraryListsCompanion Function({
      Value<int> id,
      Value<String> kind,
      Value<String> title,
      Value<String?> summary,
      Value<String?> posterSource,
      Value<String?> tmdbId,
      Value<int> createdAt,
      Value<int> updatedAt,
    });

final class $$LibraryListsTableReferences
    extends BaseReferences<_$AppDatabase, $LibraryListsTable, LibraryListRow> {
  $$LibraryListsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$LibraryListItemsTable, List<LibraryListItemRow>>
  _libraryListItemsRefsTable(_$AppDatabase db) => MultiTypedResultKey.fromTable(
    db.libraryListItems,
    aliasName: 'library_lists__id__library_list_items__list_id',
  );

  $$LibraryListItemsTableProcessedTableManager get libraryListItemsRefs {
    final manager = $$LibraryListItemsTableTableManager(
      $_db,
      $_db.libraryListItems,
    ).filter((f) => f.listId.id.sqlEquals($_itemColumn<int>('id')!));

    final cache = $_typedResult.readTableOrNull(
      _libraryListItemsRefsTable($_db),
    );
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: cache),
    );
  }
}

class $$LibraryListsTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryListsTable> {
  $$LibraryListsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get posterSource => $composableBuilder(
    column: $table.posterSource,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnFilters(column),
  );

  Expression<bool> libraryListItemsRefs(
    Expression<bool> Function($$LibraryListItemsTableFilterComposer f) f,
  ) {
    final $$LibraryListItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryListItems,
      getReferencedColumn: (t) => t.listId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryListItemsTableFilterComposer(
            $db: $db,
            $table: $db.libraryListItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LibraryListsTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryListsTable> {
  $$LibraryListsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get kind => $composableBuilder(
    column: $table.kind,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get summary => $composableBuilder(
    column: $table.summary,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get posterSource => $composableBuilder(
    column: $table.posterSource,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get tmdbId => $composableBuilder(
    column: $table.tmdbId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get createdAt => $composableBuilder(
    column: $table.createdAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get updatedAt => $composableBuilder(
    column: $table.updatedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LibraryListsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryListsTable> {
  $$LibraryListsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get summary =>
      $composableBuilder(column: $table.summary, builder: (column) => column);

  GeneratedColumn<String> get posterSource => $composableBuilder(
    column: $table.posterSource,
    builder: (column) => column,
  );

  GeneratedColumn<String> get tmdbId =>
      $composableBuilder(column: $table.tmdbId, builder: (column) => column);

  GeneratedColumn<int> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<int> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  Expression<T> libraryListItemsRefs<T extends Object>(
    Expression<T> Function($$LibraryListItemsTableAnnotationComposer a) f,
  ) {
    final $$LibraryListItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.libraryListItems,
      getReferencedColumn: (t) => t.listId,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryListItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryListItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$LibraryListsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryListsTable,
          LibraryListRow,
          $$LibraryListsTableFilterComposer,
          $$LibraryListsTableOrderingComposer,
          $$LibraryListsTableAnnotationComposer,
          $$LibraryListsTableCreateCompanionBuilder,
          $$LibraryListsTableUpdateCompanionBuilder,
          (LibraryListRow, $$LibraryListsTableReferences),
          LibraryListRow,
          PrefetchHooks Function({bool libraryListItemsRefs})
        > {
  $$LibraryListsTableTableManager(_$AppDatabase db, $LibraryListsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryListsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryListsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryListsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String?> summary = const Value.absent(),
                Value<String?> posterSource = const Value.absent(),
                Value<String?> tmdbId = const Value.absent(),
                Value<int> createdAt = const Value.absent(),
                Value<int> updatedAt = const Value.absent(),
              }) => LibraryListsCompanion(
                id: id,
                kind: kind,
                title: title,
                summary: summary,
                posterSource: posterSource,
                tmdbId: tmdbId,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String kind,
                required String title,
                Value<String?> summary = const Value.absent(),
                Value<String?> posterSource = const Value.absent(),
                Value<String?> tmdbId = const Value.absent(),
                required int createdAt,
                required int updatedAt,
              }) => LibraryListsCompanion.insert(
                id: id,
                kind: kind,
                title: title,
                summary: summary,
                posterSource: posterSource,
                tmdbId: tmdbId,
                createdAt: createdAt,
                updatedAt: updatedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LibraryListsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({libraryListItemsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [
                if (libraryListItemsRefs) db.libraryListItems,
              ],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (libraryListItemsRefs)
                    await $_getPrefetchedData<
                      LibraryListRow,
                      $LibraryListsTable,
                      LibraryListItemRow
                    >(
                      currentTable: table,
                      referencedTable: $$LibraryListsTableReferences
                          ._libraryListItemsRefsTable(db),
                      managerFromTypedResult: (p0) =>
                          $$LibraryListsTableReferences(
                            db,
                            table,
                            p0,
                          ).libraryListItemsRefs,
                      referencedItemsForCurrentItem: (item, referencedItems) =>
                          referencedItems.where((e) => e.listId == item.id),
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$LibraryListsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryListsTable,
      LibraryListRow,
      $$LibraryListsTableFilterComposer,
      $$LibraryListsTableOrderingComposer,
      $$LibraryListsTableAnnotationComposer,
      $$LibraryListsTableCreateCompanionBuilder,
      $$LibraryListsTableUpdateCompanionBuilder,
      (LibraryListRow, $$LibraryListsTableReferences),
      LibraryListRow,
      PrefetchHooks Function({bool libraryListItemsRefs})
    >;
typedef $$LibraryListItemsTableCreateCompanionBuilder =
    LibraryListItemsCompanion Function({
      required int listId,
      required int itemId,
      Value<int> sortOrder,
      Value<int> rowid,
    });
typedef $$LibraryListItemsTableUpdateCompanionBuilder =
    LibraryListItemsCompanion Function({
      Value<int> listId,
      Value<int> itemId,
      Value<int> sortOrder,
      Value<int> rowid,
    });

final class $$LibraryListItemsTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $LibraryListItemsTable,
          LibraryListItemRow
        > {
  $$LibraryListItemsTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $LibraryListsTable _listIdTable(_$AppDatabase db) => db.libraryLists
      .createAlias('library_list_items__list_id__library_lists__id');

  $$LibraryListsTableProcessedTableManager get listId {
    final $_column = $_itemColumn<int>('list_id')!;

    final manager = $$LibraryListsTableTableManager(
      $_db,
      $_db.libraryLists,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_listIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }

  static $LibraryItemsTable _itemIdTable(_$AppDatabase db) => db.libraryItems
      .createAlias('library_list_items__item_id__library_items__id');

  $$LibraryItemsTableProcessedTableManager get itemId {
    final $_column = $_itemColumn<int>('item_id')!;

    final manager = $$LibraryItemsTableTableManager(
      $_db,
      $_db.libraryItems,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_itemIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LibraryListItemsTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryListItemsTable> {
  $$LibraryListItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnFilters(column),
  );

  $$LibraryListsTableFilterComposer get listId {
    final $$LibraryListsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.libraryLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryListsTableFilterComposer(
            $db: $db,
            $table: $db.libraryLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryItemsTableFilterComposer get itemId {
    final $$LibraryItemsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableFilterComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryListItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryListItemsTable> {
  $$LibraryListItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get sortOrder => $composableBuilder(
    column: $table.sortOrder,
    builder: (column) => ColumnOrderings(column),
  );

  $$LibraryListsTableOrderingComposer get listId {
    final $$LibraryListsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.libraryLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryListsTableOrderingComposer(
            $db: $db,
            $table: $db.libraryLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryItemsTableOrderingComposer get itemId {
    final $$LibraryItemsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableOrderingComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryListItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryListItemsTable> {
  $$LibraryListItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get sortOrder =>
      $composableBuilder(column: $table.sortOrder, builder: (column) => column);

  $$LibraryListsTableAnnotationComposer get listId {
    final $$LibraryListsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.listId,
      referencedTable: $db.libraryLists,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryListsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryLists,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$LibraryItemsTableAnnotationComposer get itemId {
    final $$LibraryItemsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.itemId,
      referencedTable: $db.libraryItems,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$LibraryItemsTableAnnotationComposer(
            $db: $db,
            $table: $db.libraryItems,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryListItemsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryListItemsTable,
          LibraryListItemRow,
          $$LibraryListItemsTableFilterComposer,
          $$LibraryListItemsTableOrderingComposer,
          $$LibraryListItemsTableAnnotationComposer,
          $$LibraryListItemsTableCreateCompanionBuilder,
          $$LibraryListItemsTableUpdateCompanionBuilder,
          (LibraryListItemRow, $$LibraryListItemsTableReferences),
          LibraryListItemRow,
          PrefetchHooks Function({bool listId, bool itemId})
        > {
  $$LibraryListItemsTableTableManager(
    _$AppDatabase db,
    $LibraryListItemsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryListItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryListItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryListItemsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> listId = const Value.absent(),
                Value<int> itemId = const Value.absent(),
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryListItemsCompanion(
                listId: listId,
                itemId: itemId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required int listId,
                required int itemId,
                Value<int> sortOrder = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryListItemsCompanion.insert(
                listId: listId,
                itemId: itemId,
                sortOrder: sortOrder,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LibraryListItemsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({listId = false, itemId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (listId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.listId,
                                referencedTable:
                                    $$LibraryListItemsTableReferences
                                        ._listIdTable(db),
                                referencedColumn:
                                    $$LibraryListItemsTableReferences
                                        ._listIdTable(db)
                                        .id,
                              )
                              as T;
                    }
                    if (itemId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.itemId,
                                referencedTable:
                                    $$LibraryListItemsTableReferences
                                        ._itemIdTable(db),
                                referencedColumn:
                                    $$LibraryListItemsTableReferences
                                        ._itemIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$LibraryListItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryListItemsTable,
      LibraryListItemRow,
      $$LibraryListItemsTableFilterComposer,
      $$LibraryListItemsTableOrderingComposer,
      $$LibraryListItemsTableAnnotationComposer,
      $$LibraryListItemsTableCreateCompanionBuilder,
      $$LibraryListItemsTableUpdateCompanionBuilder,
      (LibraryListItemRow, $$LibraryListItemsTableReferences),
      LibraryListItemRow,
      PrefetchHooks Function({bool listId, bool itemId})
    >;
typedef $$LibraryScanStatesTableCreateCompanionBuilder =
    LibraryScanStatesCompanion Function({
      required String mountId,
      Value<int> scanId,
      Value<String> status,
      Value<String?> pending,
      Value<int?> startedAt,
      Value<int?> finishedAt,
      Value<String?> lastError,
      Value<int> rowid,
    });
typedef $$LibraryScanStatesTableUpdateCompanionBuilder =
    LibraryScanStatesCompanion Function({
      Value<String> mountId,
      Value<int> scanId,
      Value<String> status,
      Value<String?> pending,
      Value<int?> startedAt,
      Value<int?> finishedAt,
      Value<String?> lastError,
      Value<int> rowid,
    });

final class $$LibraryScanStatesTableReferences
    extends
        BaseReferences<
          _$AppDatabase,
          $LibraryScanStatesTable,
          LibraryScanStateRow
        > {
  $$LibraryScanStatesTableReferences(
    super.$_db,
    super.$_table,
    super.$_typedResult,
  );

  static $MountsTable _mountIdTable(_$AppDatabase db) =>
      db.mounts.createAlias('library_scan_states__mount_id__mounts__id');

  $$MountsTableProcessedTableManager get mountId {
    final $_column = $_itemColumn<String>('mount_id')!;

    final manager = $$MountsTableTableManager(
      $_db,
      $_db.mounts,
    ).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_mountIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(
      manager.$state.copyWith(prefetchedData: [item]),
    );
  }
}

class $$LibraryScanStatesTableFilterComposer
    extends Composer<_$AppDatabase, $LibraryScanStatesTable> {
  $$LibraryScanStatesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get scanId => $composableBuilder(
    column: $table.scanId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get pending => $composableBuilder(
    column: $table.pending,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnFilters(column),
  );

  $$MountsTableFilterComposer get mountId {
    final $$MountsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.mountId,
      referencedTable: $db.mounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MountsTableFilterComposer(
            $db: $db,
            $table: $db.mounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryScanStatesTableOrderingComposer
    extends Composer<_$AppDatabase, $LibraryScanStatesTable> {
  $$LibraryScanStatesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get scanId => $composableBuilder(
    column: $table.scanId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get status => $composableBuilder(
    column: $table.status,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get pending => $composableBuilder(
    column: $table.pending,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get startedAt => $composableBuilder(
    column: $table.startedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get lastError => $composableBuilder(
    column: $table.lastError,
    builder: (column) => ColumnOrderings(column),
  );

  $$MountsTableOrderingComposer get mountId {
    final $$MountsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.mountId,
      referencedTable: $db.mounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MountsTableOrderingComposer(
            $db: $db,
            $table: $db.mounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryScanStatesTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibraryScanStatesTable> {
  $$LibraryScanStatesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get scanId =>
      $composableBuilder(column: $table.scanId, builder: (column) => column);

  GeneratedColumn<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get pending =>
      $composableBuilder(column: $table.pending, builder: (column) => column);

  GeneratedColumn<int> get startedAt =>
      $composableBuilder(column: $table.startedAt, builder: (column) => column);

  GeneratedColumn<int> get finishedAt => $composableBuilder(
    column: $table.finishedAt,
    builder: (column) => column,
  );

  GeneratedColumn<String> get lastError =>
      $composableBuilder(column: $table.lastError, builder: (column) => column);

  $$MountsTableAnnotationComposer get mountId {
    final $$MountsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.mountId,
      referencedTable: $db.mounts,
      getReferencedColumn: (t) => t.id,
      builder:
          (
            joinBuilder, {
            $addJoinBuilderToRootComposer,
            $removeJoinBuilderFromRootComposer,
          }) => $$MountsTableAnnotationComposer(
            $db: $db,
            $table: $db.mounts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer:
                $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$LibraryScanStatesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryScanStatesTable,
          LibraryScanStateRow,
          $$LibraryScanStatesTableFilterComposer,
          $$LibraryScanStatesTableOrderingComposer,
          $$LibraryScanStatesTableAnnotationComposer,
          $$LibraryScanStatesTableCreateCompanionBuilder,
          $$LibraryScanStatesTableUpdateCompanionBuilder,
          (LibraryScanStateRow, $$LibraryScanStatesTableReferences),
          LibraryScanStateRow,
          PrefetchHooks Function({bool mountId})
        > {
  $$LibraryScanStatesTableTableManager(
    _$AppDatabase db,
    $LibraryScanStatesTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibraryScanStatesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibraryScanStatesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibraryScanStatesTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> mountId = const Value.absent(),
                Value<int> scanId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> pending = const Value.absent(),
                Value<int?> startedAt = const Value.absent(),
                Value<int?> finishedAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryScanStatesCompanion(
                mountId: mountId,
                scanId: scanId,
                status: status,
                pending: pending,
                startedAt: startedAt,
                finishedAt: finishedAt,
                lastError: lastError,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String mountId,
                Value<int> scanId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> pending = const Value.absent(),
                Value<int?> startedAt = const Value.absent(),
                Value<int?> finishedAt = const Value.absent(),
                Value<String?> lastError = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibraryScanStatesCompanion.insert(
                mountId: mountId,
                scanId: scanId,
                status: status,
                pending: pending,
                startedAt: startedAt,
                finishedAt: finishedAt,
                lastError: lastError,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable(table),
                  $$LibraryScanStatesTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({mountId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (mountId) {
                      state =
                          state.withJoin(
                                currentTable: table,
                                currentColumn: table.mountId,
                                referencedTable:
                                    $$LibraryScanStatesTableReferences
                                        ._mountIdTable(db),
                                referencedColumn:
                                    $$LibraryScanStatesTableReferences
                                        ._mountIdTable(db)
                                        .id,
                              )
                              as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$LibraryScanStatesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryScanStatesTable,
      LibraryScanStateRow,
      $$LibraryScanStatesTableFilterComposer,
      $$LibraryScanStatesTableOrderingComposer,
      $$LibraryScanStatesTableAnnotationComposer,
      $$LibraryScanStatesTableCreateCompanionBuilder,
      $$LibraryScanStatesTableUpdateCompanionBuilder,
      (LibraryScanStateRow, $$LibraryScanStatesTableReferences),
      LibraryScanStateRow,
      PrefetchHooks Function({bool mountId})
    >;
typedef $$LibrarySettingsTableCreateCompanionBuilder =
    LibrarySettingsCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$LibrarySettingsTableUpdateCompanionBuilder =
    LibrarySettingsCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$LibrarySettingsTableFilterComposer
    extends Composer<_$AppDatabase, $LibrarySettingsTable> {
  $$LibrarySettingsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LibrarySettingsTableOrderingComposer
    extends Composer<_$AppDatabase, $LibrarySettingsTable> {
  $$LibrarySettingsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LibrarySettingsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LibrarySettingsTable> {
  $$LibrarySettingsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$LibrarySettingsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibrarySettingsTable,
          LibrarySettingRow,
          $$LibrarySettingsTableFilterComposer,
          $$LibrarySettingsTableOrderingComposer,
          $$LibrarySettingsTableAnnotationComposer,
          $$LibrarySettingsTableCreateCompanionBuilder,
          $$LibrarySettingsTableUpdateCompanionBuilder,
          (
            LibrarySettingRow,
            BaseReferences<
              _$AppDatabase,
              $LibrarySettingsTable,
              LibrarySettingRow
            >,
          ),
          LibrarySettingRow,
          PrefetchHooks Function()
        > {
  $$LibrarySettingsTableTableManager(
    _$AppDatabase db,
    $LibrarySettingsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LibrarySettingsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LibrarySettingsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LibrarySettingsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LibrarySettingsCompanion(
                key: key,
                value: value,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => LibrarySettingsCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable(table), BaseReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LibrarySettingsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibrarySettingsTable,
      LibrarySettingRow,
      $$LibrarySettingsTableFilterComposer,
      $$LibrarySettingsTableOrderingComposer,
      $$LibrarySettingsTableAnnotationComposer,
      $$LibrarySettingsTableCreateCompanionBuilder,
      $$LibrarySettingsTableUpdateCompanionBuilder,
      (
        LibrarySettingRow,
        BaseReferences<_$AppDatabase, $LibrarySettingsTable, LibrarySettingRow>,
      ),
      LibrarySettingRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$DownloadedMediaTableTableManager get downloadedMedia =>
      $$DownloadedMediaTableTableManager(_db, _db.downloadedMedia);
  $$DownloadOwnersTableTableManager get downloadOwners =>
      $$DownloadOwnersTableTableManager(_db, _db.downloadOwners);
  $$DownloadQueueTableTableManager get downloadQueue =>
      $$DownloadQueueTableTableManager(_db, _db.downloadQueue);
  $$ApiCacheTableTableManager get apiCache =>
      $$ApiCacheTableTableManager(_db, _db.apiCache);
  $$OfflineWatchProgressTableTableManager get offlineWatchProgress =>
      $$OfflineWatchProgressTableTableManager(_db, _db.offlineWatchProgress);
  $$SyncRulesTableTableManager get syncRules =>
      $$SyncRulesTableTableManager(_db, _db.syncRules);
  $$SyncRuleDownloadsTableTableManager get syncRuleDownloads =>
      $$SyncRuleDownloadsTableTableManager(_db, _db.syncRuleDownloads);
  $$DownloadCollectionsTableTableManager get downloadCollections =>
      $$DownloadCollectionsTableTableManager(_db, _db.downloadCollections);
  $$DownloadCollectionSyncsTableTableManager get downloadCollectionSyncs =>
      $$DownloadCollectionSyncsTableTableManager(
        _db,
        _db.downloadCollectionSyncs,
      );
  $$ConnectionsTableTableManager get connections =>
      $$ConnectionsTableTableManager(_db, _db.connections);
  $$ProfilesTableTableManager get profiles =>
      $$ProfilesTableTableManager(_db, _db.profiles);
  $$ProfileConnectionsTableTableManager get profileConnections =>
      $$ProfileConnectionsTableTableManager(_db, _db.profileConnections);
  $$MusicSessionsTableTableManager get musicSessions =>
      $$MusicSessionsTableTableManager(_db, _db.musicSessions);
  $$MountsTableTableManager get mounts =>
      $$MountsTableTableManager(_db, _db.mounts);
  $$LibraryItemsTableTableManager get libraryItems =>
      $$LibraryItemsTableTableManager(_db, _db.libraryItems);
  $$LibraryFilesTableTableManager get libraryFiles =>
      $$LibraryFilesTableTableManager(_db, _db.libraryFiles);
  $$LibraryUserStatesTableTableManager get libraryUserStates =>
      $$LibraryUserStatesTableTableManager(_db, _db.libraryUserStates);
  $$LibraryGenresTableTableManager get libraryGenres =>
      $$LibraryGenresTableTableManager(_db, _db.libraryGenres);
  $$LibraryItemGenresTableTableManager get libraryItemGenres =>
      $$LibraryItemGenresTableTableManager(_db, _db.libraryItemGenres);
  $$LibraryPeopleTableTableManager get libraryPeople =>
      $$LibraryPeopleTableTableManager(_db, _db.libraryPeople);
  $$LibraryCreditsTableTableManager get libraryCredits =>
      $$LibraryCreditsTableTableManager(_db, _db.libraryCredits);
  $$LibraryListsTableTableManager get libraryLists =>
      $$LibraryListsTableTableManager(_db, _db.libraryLists);
  $$LibraryListItemsTableTableManager get libraryListItems =>
      $$LibraryListItemsTableTableManager(_db, _db.libraryListItems);
  $$LibraryScanStatesTableTableManager get libraryScanStates =>
      $$LibraryScanStatesTableTableManager(_db, _db.libraryScanStates);
  $$LibrarySettingsTableTableManager get librarySettings =>
      $$LibrarySettingsTableTableManager(_db, _db.librarySettings);
}
