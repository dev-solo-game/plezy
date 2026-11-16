import 'dart:math' as math;

import '../../database/app_database.dart';
import '../library_repository.dart';

/// Four-tier monotonic scraping weights:
/// `matchLocked (4) > matched (3) > unmatched (2) > pending (1)`.
abstract final class MatchStatusRank {
  static const int pending = 1;
  static const int unmatched = 2;
  static const int matched = 3;
  static const int matchLocked = 4;

  static int fromItem(LibraryItemRow item) {
    if (item.locked || item.metadataSource == 'nfo') return matchLocked;
    if (item.metadataSource != null && item.metadataSource!.isNotEmpty) return matched;
    if (item.scrapedAt != null) return unmatched;
    return pending;
  }

  static int fromFile(LibraryFileRow file, {LibraryItemRow? item}) {
    if (file.matchLocked || item?.locked == true || item?.metadataSource == 'nfo') {
      return matchLocked;
    }
    if (file.matchState == LibraryMatchStates.matched ||
        (item?.metadataSource != null && item!.metadataSource!.isNotEmpty)) {
      return matched;
    }
    if (file.matchState == LibraryMatchStates.unmatched || item?.scrapedAt != null) {
      return unmatched;
    }
    return pending;
  }
}

/// Decides whether an incoming [remote] metadata/file state may replace [local]
/// under the monotonic state machine and calibrated LWW rules.
bool shouldOverrideEntity({
  required bool remoteDeleted,
  required bool localDeleted,
  required int remoteMatchStatus,
  required int localMatchStatus,
  required int remoteUpdatedAt,
  required int localUpdatedAt,
  bool explicitUnlock = false,
}) {
  if (remoteDeleted != localDeleted) {
    return remoteUpdatedAt >= localUpdatedAt;
  }
  if (explicitUnlock) {
    return remoteUpdatedAt >= localUpdatedAt;
  }
  if (remoteMatchStatus != localMatchStatus) {
    return remoteMatchStatus > localMatchStatus;
  }
  return remoteUpdatedAt >= localUpdatedAt;
}

/// Merges two Quark incremental checkpoints (`<rootFolderId>:<watermarkMs>`),
/// preserving the higher server watermark when both share the same root folder.
String? mergeQuarkCheckpoint(String? local, String? remote) {
  final cleanLocal = local?.trim();
  final cleanRemote = remote?.trim();
  if (cleanLocal == null || cleanLocal.isEmpty) {
    return (cleanRemote == null || cleanRemote.isEmpty) ? null : cleanRemote;
  }
  if (cleanRemote == null || cleanRemote.isEmpty) return cleanLocal;

  final localSep = cleanLocal.indexOf(':');
  final remoteSep = cleanRemote.indexOf(':');
  if (localSep <= 0 || remoteSep <= 0) return cleanRemote;

  final localRoot = cleanLocal.substring(0, localSep);
  final remoteRoot = cleanRemote.substring(0, remoteSep);
  if (localRoot != remoteRoot) return cleanRemote;

  final localWatermark = int.tryParse(cleanLocal.substring(localSep + 1));
  final remoteWatermark = int.tryParse(cleanRemote.substring(remoteSep + 1));
  if (localWatermark == null) return cleanRemote;
  if (remoteWatermark == null) return cleanLocal;

  return '$localRoot:${math.max(localWatermark, remoteWatermark)}';
}

/// Active synchronization phase reported by [LanPeerSyncService] and [SyncAndScanCoordinator].
enum SyncPhase { idle, connecting, pulling, applying, pushing, probingMounts }

/// Immutable progress snapshot for synchronization across LAN P2P and Cloud Sync.
class SyncProgress {
  const SyncProgress({
    this.phase = SyncPhase.idle,
    this.processed = 0,
    this.total = 0,
    this.peerName,
  });

  static const SyncProgress idle = SyncProgress();

  final SyncPhase phase;
  final int processed;
  final int total;
  final String? peerName;

  bool get isActive => phase != SyncPhase.idle;

  double? get fraction => (total > 0 && processed >= 0) ? (processed / total).clamp(0.0, 1.0) : null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SyncProgress &&
          other.phase == phase &&
          other.processed == processed &&
          other.total == total &&
          other.peerName == peerName;

  @override
  int get hashCode => Object.hash(phase, processed, total, peerName);
}
