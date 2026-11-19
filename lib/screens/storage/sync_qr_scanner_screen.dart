import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_text_field.dart';
import '../../i18n/strings.g.dart';
import '../../library/sync/sync_coordinator.dart';
import '../../utils/snackbar_helper.dart';
import '../../widgets/app_icon.dart';
import 'sync_settings_screen.dart';

/// Maps QR authorization errors from [SyncAndScanCoordinator.confirmQrUri] into
/// user-facing localized messages.
String formatSyncQrAuthError(Object error) {
  if (error is SyncQrAuthException) {
    return switch (error.code) {
      SyncQrAuthErrorCode.notSignedIn => t.sync.qrErrNotSignedIn,
      SyncQrAuthErrorCode.invalidQrUri => t.sync.qrErrInvalidUri,
      SyncQrAuthErrorCode.serverMismatch => t.sync.qrErrServerMismatch(
        target: error.targetServer ?? '',
        current: error.currentServer ?? '',
      ),
      SyncQrAuthErrorCode.expired => t.sync.qrErrExpired,
    };
  }
  if (error is FormatException) return t.sync.qrErrInvalidUri;
  if (error is StateError) return t.sync.qrErrNotSignedIn;
  return '$error';
}

/// Camera QR scanner screen on Mobile allowing a signed-in user (Official or
/// Self-Hosted Sync) to authorize a PC or TV device by scanning its QR code.
class SyncQrScannerScreen extends StatefulWidget {
  const SyncQrScannerScreen({super.key, @visibleForTesting this.cameraPreviewOverride});

  @visibleForTesting
  final Widget? cameraPreviewOverride;

  @override
  State<SyncQrScannerScreen> createState() => _SyncQrScannerScreenState();
}

class _SyncQrScannerScreenState extends State<SyncQrScannerScreen> {
  MobileScannerController? _controller;
  bool _isProcessing = false;
  bool _hasError = false;
  String? _errorMessage;
  bool _torchEnabled = false;

  bool get _supportsNativeCamera =>
      widget.cameraPreviewOverride == null && (Platform.isAndroid || Platform.isIOS || Platform.isMacOS);

  @override
  void initState() {
    super.initState();
    if (_supportsNativeCamera) {
      _controller = MobileScannerController();
    }
  }

  @override
  void dispose() {
    unawaited(_controller?.dispose());
    super.dispose();
  }

  Future<void> _authorizeUri(String raw) async {
    if (_isProcessing || raw.trim().isEmpty) return;
    final sync = context.read<SyncAndScanCoordinator>();
    setState(() {
      _isProcessing = true;
      _hasError = false;
      _errorMessage = null;
    });
    try {
      await sync.confirmQrUri(raw.trim());
      if (!mounted) return;
      showAppSnackBar(context, t.sync.qrScanSuccess);
      Navigator.of(context).pop(true);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isProcessing = false;
        _hasError = true;
        _errorMessage = formatSyncQrAuthError(e);
      });
    }
  }

  Future<void> _promptManualPaste() async {
    final submitted = await showDialog<String>(context: context, builder: (_) => const _ManualQrPasteDialog());
    if (submitted != null && submitted.isNotEmpty && mounted) {
      await _authorizeUri(submitted);
    }
  }

  Future<void> _toggleTorch() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.toggleTorch();
    if (mounted) {
      setState(() => _torchEnabled = !_torchEnabled);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sync = context.watch<SyncAndScanCoordinator>();
    final sess = sync.session;
    final theme = Theme.of(context);

    if (sess == null) {
      return Scaffold(
        appBar: AppBar(title: Text(t.sync.qrScannerTitle)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AppIcon(Symbols.lock_person_rounded, size: 64, color: theme.colorScheme.primary),
                  const SizedBox(height: 16),
                  Text(t.sync.scanQrRequireLoginTitle, style: theme.textTheme.titleLarge, textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(
                    t.sync.scanQrRequireLoginBody,
                    style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: () {
                      Navigator.of(
                        context,
                      ).pushReplacement(MaterialPageRoute<void>(builder: (_) => const SyncSettingsScreen()));
                    },
                    icon: const AppIcon(Symbols.login_rounded),
                    label: Text(t.sync.goToSyncLogin),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    final modeLabel = sess.serverKind == SyncServerKind.official ? t.sync.officialBadge : t.sync.selfHostedBadge;

    return Scaffold(
      appBar: AppBar(
        title: Text(t.sync.qrScannerTitle),
        actions: [
          if (_controller != null)
            IconButton(
              onPressed: () => unawaited(_toggleTorch()),
              icon: AppIcon(_torchEnabled ? Symbols.flash_on_rounded : Symbols.flash_off_rounded),
            ),
        ],
      ),
      body: Column(
        children: [
          Material(
            color: theme.colorScheme.secondaryContainer,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              child: Row(
                children: [
                  AppIcon(Symbols.verified_user_rounded, size: 20, color: theme.colorScheme.onSecondaryContainer),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.sync.qrScannerAccountBanner(mode: modeLabel, name: sess.username),
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSecondaryContainer,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (sess.serverKind == SyncServerKind.selfHosted)
                          Text(
                            sess.serverUrl,
                            style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSecondaryContainer),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (widget.cameraPreviewOverride != null)
                  widget.cameraPreviewOverride!
                else if (_controller != null)
                  MobileScanner(
                    controller: _controller!,
                    onDetect: (capture) {
                      if (_isProcessing || _hasError) return;
                      for (final barcode in capture.barcodes) {
                        final raw = barcode.rawValue;
                        if (raw != null && raw.trim().isNotEmpty) {
                          unawaited(_authorizeUri(raw));
                          break;
                        }
                      }
                    },
                    errorBuilder: (ctx, error) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const AppIcon(Symbols.no_photography_rounded, size: 64, color: Colors.grey),
                            const SizedBox(height: 16),
                            Text(
                              error.errorCode == MobileScannerErrorCode.permissionDenied
                                  ? t.sync.cameraPermissionRequired
                                  : t.sync.cameraError(error: error.errorDetails?.message ?? error.errorCode.name),
                              textAlign: TextAlign.center,
                            ),
                          ],
                        ),
                      ),
                    ),
                  )
                else
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const AppIcon(Symbols.qr_code_scanner_rounded, size: 64),
                          const SizedBox(height: 12),
                          Text(t.sync.qrAuthorizeHint, textAlign: TextAlign.center, style: theme.textTheme.bodyMedium),
                        ],
                      ),
                    ),
                  ),
                if (_isProcessing)
                  ColoredBox(
                    color: Colors.black54,
                    child: Center(
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const CircularProgressIndicator(),
                              const SizedBox(height: 12),
                              Text(t.sync.syncing),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_hasError && _errorMessage != null) ...[
                    Material(
                      color: theme.colorScheme.errorContainer,
                      borderRadius: const BorderRadius.all(Radius.circular(12)),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(_errorMessage!, style: TextStyle(color: theme.colorScheme.onErrorContainer)),
                            ),
                            const SizedBox(width: 8),
                            TextButton(
                              onPressed: () {
                                setState(() {
                                  _hasError = false;
                                  _errorMessage = null;
                                });
                              },
                              child: Text(t.sync.qrRescanButton),
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Text(
                    t.sync.qrScannerInstruction,
                    style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton.icon(
                    onPressed: _isProcessing ? null : () => unawaited(_promptManualPaste()),
                    icon: const AppIcon(Symbols.content_paste_rounded),
                    label: Text(t.sync.qrPasteManualButton),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ManualQrPasteDialog extends StatefulWidget {
  const _ManualQrPasteDialog();

  @override
  State<_ManualQrPasteDialog> createState() => _ManualQrPasteDialogState();
}

class _ManualQrPasteDialogState extends State<_ManualQrPasteDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.sync.qrAuthorizeTitle),
      content: SizedBox(
        width: 400,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(t.sync.qrAuthorizeHint, style: Theme.of(context).textTheme.bodySmall),
              const SizedBox(height: 12),
              FocusableTextField(
                controller: _controller,
                autofocus: true,
                decoration: const InputDecoration(hintText: 'ttplay://qr-auth?...'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(null), child: Text(t.common.cancel)),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text.trim()),
          child: Text(t.sync.qrAuthorizeButton),
        ),
      ],
    );
  }
}
