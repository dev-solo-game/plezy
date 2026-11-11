import 'dart:async';

import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../i18n/strings.g.dart';
import '../../storage/drivers/quark_pc_qr_login.dart';
import '../../storage/drivers/quark_qr_login.dart';
import '../../storage/drivers/quark_storage_driver.dart';
import '../../storage/storage_driver.dart';

/// Shows a Quark login QR code and resolves with the mount's stored secret
/// once the user confirms on their phone — a cookie in web mode, the desktop
/// session string in PC mode. Resolves with null when dismissed.
Future<String?> showQuarkQrLoginDialog(BuildContext context, {QuarkMode mode = QuarkMode.web}) {
  return showDialog<String>(context: context, builder: (_) => _QuarkQrLoginDialog(mode: mode));
}

class _QuarkQrLoginDialog extends StatefulWidget {
  const _QuarkQrLoginDialog({required this.mode});

  final QuarkMode mode;

  @override
  State<_QuarkQrLoginDialog> createState() => _QuarkQrLoginDialogState();
}

class _QuarkQrLoginDialogState extends State<_QuarkQrLoginDialog> {
  static const Duration _pollInterval = Duration(seconds: 2);
  static const double _qrSize = 220;

  late final QuarkQrAuthenticator _login = widget.mode == QuarkMode.pc ? QuarkPcQrLogin() : QuarkQrLogin();
  QuarkQrTicket? _ticket;
  bool _expired = false;
  String? _error;
  Timer? _timer;
  bool _polling = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _login.close();
    super.dispose();
  }

  Future<void> _start() async {
    _timer?.cancel();
    setState(() {
      _ticket = null;
      _expired = false;
      _error = null;
    });
    try {
      final ticket = await _login.start();
      if (!mounted) return;
      setState(() => _ticket = ticket);
      _timer = Timer.periodic(_pollInterval, (_) => unawaited(_poll(ticket)));
    } catch (e) {
      if (mounted) setState(() => _error = e is StorageException ? e.message : '$e');
    }
  }

  Future<void> _poll(QuarkQrTicket ticket) async {
    // A slow response must not overlap the next tick.
    if (_polling) return;
    _polling = true;
    try {
      final status = await _login.poll(ticket);
      if (!mounted || _ticket != ticket) return;
      switch (status) {
        case QuarkQrWaiting():
          break;
        case QuarkQrExpired():
          _timer?.cancel();
          setState(() => _expired = true);
        case QuarkQrSuccess(:final cookie):
          _timer?.cancel();
          Navigator.of(context).pop(cookie);
      }
    } on StorageException catch (e) {
      // A dropped connection is worth riding out; anything else is final.
      if (e.kind != StorageErrorKind.network && mounted && _ticket == ticket) {
        _timer?.cancel();
        setState(() => _error = e.message);
      }
    } finally {
      _polling = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ticket = _ticket;
    final error = _error;
    final stale = _expired || error != null;

    final Widget code;
    if (ticket == null && error == null) {
      code = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [const CircularProgressIndicator(), const SizedBox(height: 16), Text(t.storage.quarkScanLoading)],
      );
    } else if (ticket == null) {
      code = const SizedBox.shrink();
    } else {
      code = Opacity(
        opacity: stale ? 0.15 : 1,
        child: QrImageView(
          data: ticket.qrContent,
          size: _qrSize,
          version: QrVersions.auto,
          backgroundColor: Colors.white,
        ),
      );
    }

    return AlertDialog(
      title: Text(t.storage.quarkScanTitle),
      content: SizedBox(
        width: 300,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DecoratedBox(
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: SizedBox.square(
                  dimension: _qrSize,
                  child: Center(child: code),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              error ?? (_expired ? t.storage.quarkScanExpired : t.storage.quarkScanHint),
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(color: error != null ? theme.colorScheme.error : null),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t.common.cancel)),
        if (stale) FilledButton(autofocus: true, onPressed: _start, child: Text(t.storage.quarkScanNew)),
      ],
    );
  }
}
