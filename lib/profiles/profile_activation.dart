import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../database/download_operations.dart';
import '../i18n/strings.g.dart';
import '../utils/snackbar_helper.dart';
import '../utils/app_logger.dart';
import '../services/system_shelf_service.dart';
import 'active_profile_binder.dart';
import 'active_profile_provider.dart';
import 'profile.dart';

/// How a UI-driven activation attempt ended. `cancelled` (user backed out
/// of a PIN dialog) is not an error and must not surface a failure message.
enum ProfileActivationOutcome { activated, cancelled, failed }

class _ProfileActivationResult {
  const _ProfileActivationResult(this.outcome, {this.rollbackProfile, this.activationGeneration});

  final ProfileActivationOutcome outcome;
  final Profile? rollbackProfile;
  final int? activationGeneration;
}

Future<_ProfileActivationResult> _activateVerifiedProfile(BuildContext context, Profile profile) async {
  final active = context.read<ActiveProfileProvider>();
  final binder = context.read<ActiveProfileBinder>();
  final shelf = SystemShelfService();
  final oldOwner = active.activeId;
  final requestGeneration = active.beginIdentityMutationRequest();
  int? activationGeneration;

  try {
    if (oldOwner != null && oldOwner != profile.id) {
      await shelf.endProfileSession(oldOwner);
      if (!active.isIdentityMutationRequestCurrent(requestGeneration)) {
        return const _ProfileActivationResult(ProfileActivationOutcome.cancelled);
      }
    }

    // Capture the rollback owner only once this verified request has been
    // admitted. Protected-profile verification may have awaited while another
    // profile became authoritative, so anything captured by the UI caller is
    // stale by this point.
    final rollbackProfile = active.active;
    binder.markUserInitiatedActivation(profile.id);
    final activation = active.activate(profile);
    activationGeneration = active.identityMutationGeneration;
    final activated = await activation;
    if (activated) {
      return _ProfileActivationResult(
        ProfileActivationOutcome.activated,
        rollbackProfile: rollbackProfile,
        activationGeneration: activationGeneration,
      );
    }
  } catch (error, stackTrace) {
    final stillCurrent = activationGeneration == null
        ? active.isIdentityMutationRequestCurrent(requestGeneration)
        : active.identityMutationGeneration == activationGeneration;
    if (stillCurrent) {
      appLogger.w('Failed to activate profile ${profile.id}', error: error, stackTrace: stackTrace);
    }
  } finally {
    active.finishIdentityMutationRequest(requestGeneration);
  }

  final stillCurrent = activationGeneration == null
      ? active.isIdentityMutationRequestCurrent(requestGeneration)
      : active.identityMutationGeneration == activationGeneration;
  if (!stillCurrent) {
    return const _ProfileActivationResult(ProfileActivationOutcome.cancelled);
  }

  // Activation may fail or throw while the prior identity is still
  // authoritative. Admit it again, but never replay rows captured before the
  // failed switch.
  if (oldOwner != null && active.activeId == oldOwner) {
    shelf.beginProfileSession(oldOwner);
  }
  return const _ProfileActivationResult(ProfileActivationOutcome.failed);
}

/// Activate [profile] from a UI surface, then wait until the active profile's
/// server/token binding has settled. Shows the standard switch failure message
/// for activation and binding failures — but not for a PIN-dialog cancel,
/// which is the user changing their mind, not an error.
///
/// Past the PIN prompt nothing here needs [context]: a switch started from a
/// profile-scoped screen (Discover's profile menu) outlives that screen,
/// whose subtree the activation rebuilds, so the offline keep-active decision
/// and the failure message must not depend on it staying mounted.
Future<bool> switchProfileFromUi(BuildContext context, Profile profile) async {
  final activeProvider = context.read<ActiveProfileProvider>();
  final binder = context.read<ActiveProfileBinder>();
  final database = context.read<AppDatabase>();
  final shelf = SystemShelfService();
  void showSwitchFailed() {
    final message = t.errors.failedToSwitchProfile(displayName: profile.displayName);
    if (context.mounted) {
      showErrorSnackBar(context, message);
    } else {
      showGlobalErrorSnackBar(message);
    }
  }

  final activation = await _activateVerifiedProfile(context, profile);
  switch (activation.outcome) {
    case ProfileActivationOutcome.cancelled:
      return false;
    case ProfileActivationOutcome.failed:
      showSwitchFailed();
      return false;
    case ProfileActivationOutcome.activated:
      break;
  }

  final previousProfile = activation.rollbackProfile;
  var activationGeneration = activation.activationGeneration;
  if (activationGeneration == null) return false;
  bool isCurrentActivation(String expectedProfileId) =>
      activeProvider.committedIdentityGeneration == activationGeneration &&
      activeProvider.activeId == expectedProfileId;

  if (!isCurrentActivation(profile.id)) return false;
  final bound = await activeProvider.awaitBindingSettle();
  if (!isCurrentActivation(profile.id)) return false;
  if (bound) return true;

  if (binder.lastBindFailureConnectivityOnly) {
    // The bind failed purely for connectivity — identity was already verified
    // before activation (local PIN hash or the Plex /switch round-trip). When
    // the profile owns downloads, keep it active instead of rolling back: the
    // rollback profile's scope does not own them, so they would vanish from
    // the Downloads UI while the files sit on disk. OfflineModeProvider drives
    // the offline UI from the empty visible-server set. Auth-classified bind
    // failures never set the flag and keep today's rollback + snackbar.
    final ownedDownloadKeys = await database.getDownloadOwnerKeysForProfile(profile.id);
    if (!isCurrentActivation(profile.id)) return false;
    if (ownedDownloadKeys.isNotEmpty) {
      appLogger.i(
        'Profile switch: keeping ${profile.displayName} active with no reachable servers '
        '(${ownedDownloadKeys.length} offline downloads owned)',
      );
      return true;
    }
  }

  if (previousProfile != null && previousProfile.id != profile.id && isCurrentActivation(profile.id)) {
    final rollbackRequestGeneration = activeProvider.beginIdentityMutationRequest();
    try {
      await shelf.endProfileSession(profile.id);
      if (!isCurrentActivation(profile.id)) return false;

      final rollbackGeneration = await activeProvider.restoreAfterFailedActivation(
        previousProfile,
        expectedActiveId: profile.id,
        expectedCommittedGeneration: activationGeneration,
        requestGeneration: rollbackRequestGeneration,
      );
      if (rollbackGeneration == null) return false;
      activationGeneration = rollbackGeneration;
      if (!isCurrentActivation(previousProfile.id)) return false;

      binder.markUserInitiatedActivation(previousProfile.id);
      // Returning to the profile the user was already on is not a new
      // switch: its identity was verified when it became active, so reuse
      // its cached Plex Home token rather than re-validating the PIN.
      if (previousProfile.isPlexHome) binder.markPlexHomePreVerified(previousProfile.id);
      final rebind = binder.rebindActive();
      final restored = await activeProvider.awaitBindingSettle();
      if (!isCurrentActivation(previousProfile.id)) {
        await rebind;
        return false;
      }
      await rebind;
      if (!isCurrentActivation(previousProfile.id)) return false;

      if (restored) {
        shelf.beginProfileSession(previousProfile.id);
      }
    } catch (error, stackTrace) {
      appLogger.w(
        'Failed to restore ${previousProfile.id} after profile switch failure',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      activeProvider.finishIdentityMutationRequest(rollbackRequestGeneration);
    }
  }
  if (activeProvider.committedIdentityGeneration == activationGeneration) showSwitchFailed();
  return false;
}
