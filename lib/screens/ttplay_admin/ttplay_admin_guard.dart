import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../exceptions/media_server_exceptions.dart';
import '../../i18n/strings.g.dart';
import '../../session/app_session_controller.dart';
import '../../ttplay/ttplay_admin_service.dart';
import '../../ttplay/ttplay_session_binder.dart';
import '../../utils/platform_detector.dart';
import '../../widgets/app_icon.dart';

/// Shared access guard & provider helpers for PC/Mobile server-admin screens.
bool canUseTtplayAdmin({required AppSessionController? session, required TtplaySessionBinder? binder}) {
  return !PlatformDetector.isTV() &&
      (session?.isSelfHosted == true) &&
      (binder?.cloudSourceRepository != null || binder?.adminService != null);
}

AppSessionController? maybeWatchAppSession(BuildContext context) {
  try {
    return context.watch<AppSessionController?>();
  } on ProviderNotFoundException {
    return null;
  }
}

TtplaySessionBinder? maybeWatchTtplayBinder(BuildContext context) {
  try {
    return context.watch<TtplaySessionBinder?>();
  } on ProviderNotFoundException {
    return null;
  }
}

TtplaySessionBinder? maybeReadTtplayBinder(BuildContext context) {
  try {
    return context.read<TtplaySessionBinder?>();
  } on ProviderNotFoundException {
    return null;
  }
}

TtplayAdminService? resolveTtplayAdminService(BuildContext context, {bool watch = false}) {
  if (PlatformDetector.isTV()) return null;
  final binder = watch ? maybeWatchTtplayBinder(context) : maybeReadTtplayBinder(context);
  return binder?.adminService;
}

String ttplayAdminErrorText(Object error) {
  if (error is MediaServerHttpException) return error.message;
  if (error is MediaServerAuthException) return error.message;
  return '$error';
}

Widget buildTvAdminBlockedScaffold(BuildContext context, String title) {
  return Scaffold(
    appBar: AppBar(title: Text(title)),
    body: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const AppIcon(Symbols.desktop_windows_rounded, size: 48),
              const SizedBox(height: 16),
              Text(t.serverAdmin.tvAdminUnsupported, textAlign: TextAlign.center),
            ],
          ),
        ),
      ),
    ),
  );
}
