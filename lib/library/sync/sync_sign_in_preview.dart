import 'library_workspace_store.dart';
import 'sync_crypto.dart';

typedef SyncWorkPrefPreview = ({
  bool favorite,
  bool hidden,
  bool introEnabled,
  int introStartMs,
  int introEndMs,
  bool creditsEnabled,
  int creditsFromEndMs,
  int keepEasterEggMs,
});

typedef SyncListPreview = ({String title, List<String> itemWorkKeys});
typedef SyncProgressPreview = ({bool watched, int positionMs});

/// Authenticated session credentials held in memory before committing a
/// workspace switch or pushing local changes.
class PendingSyncSignIn {
  const PendingSyncSignIn({
    required this.credentials,
    required this.serverTimeMs,
    this.remoteSettings = const {},
    this.isNewAccount = false,
  });

  final SyncSessionCredentials credentials;
  final int serverTimeMs;
  final Map<String, Object?> remoteSettings;
  final bool isNewAccount;
}

/// Entity counts summarizing either the local syncable workspace or a cloud account.
class SyncLibraryStats {
  const SyncLibraryStats({
    this.sources = 0,
    this.works = 0,
    this.files = 0,
    this.lists = 0,
    this.watchProgress = 0,
    this.workPrefs = 0,
  });

  final int sources;
  final int works;
  final int files;
  final int lists;
  final int watchProgress;
  final int workPrefs;

  bool get isEmpty => sources == 0 && works == 0 && files == 0 && lists == 0 && watchProgress == 0 && workPrefs == 0;

  int get totalEntities => sources + works + files + lists;
}

enum SyncSignInDecisionReason {
  localEmpty,
  cloudEmpty,
  existingAccountArchive,
  noLocalDifferences,
  requiresMergeChoice,
}

/// Read-only snapshot of local syncable entities built without mutating Drift state.
class LocalSyncPreviewSnapshot {
  const LocalSyncPreviewSnapshot({
    this.sourcesByCanonicalKey = const {},
    this.workKeys = const {},
    this.sharedFilesCount = 0,
    this.listsByKey = const {},
    this.progressByKey = const {},
    this.workPrefsByKey = const {},
  });

  final Map<String, String> sourcesByCanonicalKey;
  final Set<String> workKeys;
  final int sharedFilesCount;
  final Map<String, SyncListPreview> listsByKey;
  final Map<String, SyncProgressPreview> progressByKey;
  final Map<String, SyncWorkPrefPreview> workPrefsByKey;

  SyncLibraryStats get stats => SyncLibraryStats(
    sources: sourcesByCanonicalKey.length,
    works: workKeys.length,
    files: sharedFilesCount,
    lists: listsByKey.length,
    watchProgress: progressByKey.length,
    workPrefs: workPrefsByKey.length,
  );
}

/// Result of comparing local syncable data against a newly authenticated cloud account.
class SyncSignInDiffPreview {
  const SyncSignInDiffPreview({
    required this.username,
    required this.serverUrl,
    required this.serverKind,
    required this.reason,
    required this.recommendedPolicy,
    required this.localStats,
    required this.cloudStats,
    this.localOnlySourceNames = const [],
    this.cloudOnlySourceNames = const [],
    this.sharedSourceNames = const [],
    this.localOnlyWorks = 0,
    this.cloudOnlyWorks = 0,
    this.localOnlyLists = 0,
    this.cloudOnlyLists = 0,
    this.conflictingLists = 0,
    this.localOnlyProgress = 0,
    this.cloudOnlyProgress = 0,
    this.conflictingProgress = 0,
    this.localOnlyOrConflictingWorkPrefs = 0,
    this.diffTruncated = false,
  });

  final String username;
  final String serverUrl;
  final SyncServerKind serverKind;
  final SyncSignInDecisionReason reason;
  final LocalMergePolicy recommendedPolicy;
  final SyncLibraryStats localStats;
  final SyncLibraryStats cloudStats;
  final List<String> localOnlySourceNames;
  final List<String> cloudOnlySourceNames;
  final List<String> sharedSourceNames;
  final int localOnlyWorks;
  final int cloudOnlyWorks;
  final int localOnlyLists;
  final int cloudOnlyLists;
  final int conflictingLists;
  final int localOnlyProgress;
  final int cloudOnlyProgress;
  final int conflictingProgress;
  final int localOnlyOrConflictingWorkPrefs;
  final bool diffTruncated;

  bool get requiresConfirmation => reason == SyncSignInDecisionReason.requiresMergeChoice;
}
