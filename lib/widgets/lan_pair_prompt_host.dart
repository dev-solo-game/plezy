import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../i18n/strings.g.dart';
import '../services/companion_remote/lan_pairing_service.dart';
import 'app_icon.dart';
import 'dialog_action_button.dart';

/// Listens to [LanPairingService] and presents at most one global top-level
/// dialog at a time when an explicit incoming LAN remote-control pairing request
/// arrives (passive UDP discovery alone never pops a modal).
class LanPairPromptHost extends StatefulWidget {
  const LanPairPromptHost({super.key, required this.child, this.countdownDuration = const Duration(seconds: 15)});

  final Widget child;
  final Duration countdownDuration;

  @override
  State<LanPairPromptHost> createState() => _LanPairPromptHostState();
}

class _LanPairPromptHostState extends State<LanPairPromptHost> {
  LanPairingService? _lan;
  bool _checkScheduled = false;
  bool _isDialogOpen = false;
  DialogRoute<bool>? _activeRoute;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final nextLan = _readOptionalLan();
    if (!identical(nextLan, _lan)) {
      _lan?.removeListener(_scheduleCheck);
      _lan = nextLan;
      _lan?.addListener(_scheduleCheck);
    }
    _scheduleCheck();
  }

  @override
  void dispose() {
    _lan?.removeListener(_scheduleCheck);
    _lan = null;
    final route = _activeRoute;
    _activeRoute = null;
    if (route != null && route.isActive) {
      route.navigator?.removeRoute(route);
    }
    super.dispose();
  }

  LanPairingService? _readOptionalLan() {
    try {
      return Provider.of<LanPairingService?>(context, listen: false);
    } on ProviderNotFoundException {
      return null;
    }
  }

  void _scheduleCheck() {
    if (!mounted || _checkScheduled || _isDialogOpen) return;
    _checkScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkScheduled = false;
      _maybePresentNextPrompt();
    });
  }

  void _maybePresentNextPrompt() {
    if (!mounted || _isDialogOpen) return;
    final lan = _lan;
    if (lan == null || !lan.isRunning) return;

    final incoming = lan.unpromptedIncomingRequests.firstOrNull;
    if (incoming == null) return;

    final navigator = Navigator.maybeOf(context, rootNavigator: true);
    if (navigator == null) return;

    final targetDeviceId = incoming.deviceId;

    _isDialogOpen = true;
    final route = DialogRoute<bool>(
      context: navigator.context,
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      barrierDismissible: true,
      traversalEdgeBehavior: TraversalEdgeBehavior.closedLoop,
      builder: (_) => LanPairPromptDialog(
        lanService: lan,
        deviceId: targetDeviceId,
        initialRequest: incoming,
        countdownDuration: widget.countdownDuration,
      ),
    );
    _activeRoute = route;

    unawaited(
      navigator
          .push<bool>(route)
          .then((accepted) {
            if (accepted != true) {
              for (final req in lan.incomingPairRequests) {
                if (req.deviceId == targetDeviceId) {
                  lan.dismissIncomingRequestPrompt(req);
                  break;
                }
              }
            }
          })
          .whenComplete(() {
            if (identical(_activeRoute, route)) {
              _activeRoute = null;
            }
            _isDialogOpen = false;
            if (mounted) _scheduleCheck();
          }),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// Global top-level modal prompt with a self-closing countdown cancel button for
/// first-time LAN device discovery and incoming pairing requests.
class LanPairPromptDialog extends StatefulWidget {
  const LanPairPromptDialog({
    super.key,
    required this.lanService,
    required this.deviceId,
    this.initialPeer,
    this.initialRequest,
    this.countdownDuration = const Duration(seconds: 15),
  });

  final LanPairingService lanService;
  final String deviceId;
  final LanDiscoveredPeer? initialPeer;
  final LanPairRequest? initialRequest;
  final Duration countdownDuration;

  @override
  State<LanPairPromptDialog> createState() => _LanPairPromptDialogState();
}

class _LanPairPromptDialogState extends State<LanPairPromptDialog> {
  static const _buttonPadding = EdgeInsets.symmetric(horizontal: 18, vertical: 14);
  static const _buttonShape = StadiumBorder();

  final _cancelFocusNode = FocusNode(debugLabel: 'lan_prompt_cancel');
  final _confirmFocusNode = FocusNode(debugLabel: 'lan_prompt_confirm');

  Timer? _countdownTimer;
  late int _remainingSeconds;
  bool _waitingForPeerConfirm = false;
  bool _busy = false;
  bool _popped = false;
  String? _error;

  LanDiscoveredPeer? _lastKnownPeer;
  LanPairRequest? _seenIncomingReq;

  @override
  void initState() {
    super.initState();
    _lastKnownPeer = widget.initialPeer;
    _seenIncomingReq = _findIncomingRequest() ?? widget.initialRequest;
    _remainingSeconds = math.max(1, widget.countdownDuration.inSeconds);
    widget.lanService.addListener(_onLanChanged);
    _startTimer();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _countdownTimer = null;
    widget.lanService.removeListener(_onLanChanged);
    _cancelFocusNode.dispose();
    _confirmFocusNode.dispose();
    super.dispose();
  }

  LanDiscoveredPeer? _findDiscoveredPeer() {
    for (final p in widget.lanService.discoveredPeers) {
      if (p.deviceId == widget.deviceId) return p;
    }
    return null;
  }

  LanPairRequest? _findIncomingRequest() {
    for (final r in widget.lanService.incomingPairRequests) {
      if (r.deviceId == widget.deviceId) return r;
    }
    return null;
  }

  void _startTimer() {
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), _onTick);
  }

  void _onTick(Timer timer) {
    if (!mounted || _popped) {
      timer.cancel();
      return;
    }
    if (_remainingSeconds <= 1) {
      _closeWithResult(false);
      return;
    }
    setState(() => _remainingSeconds--);
  }

  void _onLanChanged() {
    if (!mounted || _popped) return;
    if (!widget.lanService.isRunning || widget.lanService.isPeerTrusted(widget.deviceId)) {
      _closeWithResult(true);
      return;
    }

    final livePeer = _findDiscoveredPeer();
    if (livePeer != null) {
      _lastKnownPeer = livePeer;
    }

    final incoming = _findIncomingRequest();
    if (incoming != null && (_seenIncomingReq == null || incoming.requestedAt != _seenIncomingReq!.requestedAt)) {
      _seenIncomingReq = incoming;
      final wasWaiting = _waitingForPeerConfirm;
      _waitingForPeerConfirm = false;
      _error = null;
      _remainingSeconds = math.max(1, widget.countdownDuration.inSeconds);
      _startTimer();
      if (wasWaiting) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_popped && !_waitingForPeerConfirm) {
            _confirmFocusNode.requestFocus();
          }
        });
      }
    }
    setState(() {});
  }

  void _closeWithResult(bool result) {
    if (_popped || !mounted) return;
    _popped = true;
    _countdownTimer?.cancel();
    _countdownTimer = null;
    Navigator.of(context).pop(result);
  }

  Future<void> _onConfirmPressed(LanPairRequest? activeRequest, LanDiscoveredPeer? peer) async {
    if (_busy || _popped) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (activeRequest != null) {
        await widget.lanService.acceptPairRequest(activeRequest);
        if (mounted) _closeWithResult(true);
      } else if (peer != null) {
        await widget.lanService.requestPairWithPeer(peer);
        if (!mounted || _popped) return;
        if (widget.lanService.isPeerTrusted(widget.deviceId)) {
          _closeWithResult(true);
          return;
        }
        setState(() {
          _waitingForPeerConfirm = true;
          _remainingSeconds = math.max(1, widget.countdownDuration.inSeconds);
        });
        _startTimer();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && !_popped && _waitingForPeerConfirm) {
            _cancelFocusNode.requestFocus();
          }
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final lan = widget.lanService;

    final activeRequest = _findIncomingRequest() ?? _seenIncomingReq;
    final peer = _findDiscoveredPeer() ?? _lastKnownPeer;
    final deviceName = activeRequest?.deviceName ?? peer?.deviceName ?? widget.deviceId;
    final platform = activeRequest?.platform ?? peer?.platform ?? '';
    final myPub = lan.publicKeyBase64;
    final pairingCode =
        activeRequest?.pairingCode ??
        (peer != null && myPub != null && myPub.isNotEmpty ? peer.pairingCodeFor(myPub) : null);

    final isRequest = activeRequest != null;
    final title = isRequest ? t.sync.lanPopupRequestTitle : t.sync.lanPopupDiscoverTitle;
    final body = _waitingForPeerConfirm
        ? t.sync.lanPopupWaitingBody(device: deviceName)
        : (isRequest
              ? t.sync.lanPopupRequestBody(device: deviceName, platform: platform)
              : t.sync.lanPopupDiscoverBody(device: deviceName, platform: platform));
    final confirmLabel = isRequest ? t.sync.lanAcceptButton : t.sync.lanPairButton;

    return AlertDialog(
      icon: AppIcon(
        isRequest ? Symbols.verified_user_rounded : Symbols.devices_rounded,
        size: 32,
        color: colorScheme.primary,
      ),
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(body, style: theme.textTheme.bodyMedium),
            if (pairingCode != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: colorScheme.surfaceContainerHighest,
                  borderRadius: const BorderRadius.all(Radius.circular(10)),
                ),
                child: Text(
                  t.sync.lanPairingCode(code: pairingCode),
                  textAlign: TextAlign.center,
                  style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: 1.5),
                ),
              ),
            ],
            if (_waitingForPeerConfirm) ...[
              const SizedBox(height: 14),
              const Center(child: SizedBox.square(dimension: 20, child: CircularProgressIndicator(strokeWidth: 2))),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: colorScheme.errorContainer,
                  borderRadius: const BorderRadius.all(Radius.circular(8)),
                ),
                child: Text(_error!, style: TextStyle(color: colorScheme.onErrorContainer, fontSize: 12)),
              ),
            ],
            const SizedBox(height: 10),
            Text(
              t.sync.lanPopupLaterHint,
              style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
      actions: [
        DialogActionButton(
          focusNode: _cancelFocusNode,
          autofocus: _waitingForPeerConfirm,
          onPressed: _busy ? null : () => _closeWithResult(false),
          label: t.sync.lanPopupCancelCountdown(seconds: _remainingSeconds),
          style: TextButton.styleFrom(padding: _buttonPadding, shape: _buttonShape),
          onNavigateRight: _waitingForPeerConfirm ? null : () => _confirmFocusNode.requestFocus(),
        ),
        if (!_waitingForPeerConfirm)
          DialogActionButton(
            focusNode: _confirmFocusNode,
            autofocus: true,
            isPrimary: true,
            onPressed: _busy || (activeRequest == null && peer == null)
                ? null
                : () => unawaited(_onConfirmPressed(activeRequest, peer)),
            label: confirmLabel,
            style: FilledButton.styleFrom(padding: _buttonPadding, shape: _buttonShape),
            onNavigateLeft: () => _cancelFocusNode.requestFocus(),
          ),
      ],
    );
  }
}
