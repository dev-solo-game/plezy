import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../i18n/strings.g.dart';
import '../../mpv/mpv.dart';
import '../../storage/mount_manager.dart';
import '../../storage/storage_driver.dart';
import '../../storage/storage_mount.dart';
import '../../utils/app_logger.dart';
import '../../utils/formatters.dart';
import '../../widgets/app_icon.dart';

/// Bare-bones playback of one mounted file through the stream proxy: play,
/// pause and seek. It exists to prove the storage path end to end; library
/// playback goes through the real player screen.
class StoragePreviewScreen extends StatefulWidget {
  const StoragePreviewScreen({super.key, required this.mount, required this.entry});

  final StorageMount mount;
  final StorageEntry entry;

  @override
  State<StoragePreviewScreen> createState() => _StoragePreviewScreenState();
}

class _StoragePreviewScreenState extends State<StoragePreviewScreen> {
  Player? _player;
  String? _error;
  bool _playing = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  double? _scrubbing;
  final List<StreamSubscription<Object?>> _subscriptions = [];

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  Future<void> _start() async {
    final manager = context.read<MountManager>();
    try {
      final url = await manager.streamUrl(widget.mount, widget.entry);
      if (!mounted) return;
      final player = Player();
      _subscriptions
        ..add(player.streams.playing.listen((v) => _update(() => _playing = v)))
        ..add(player.streams.position.listen((v) => _update(() => _position = v)))
        ..add(player.streams.duration.listen((v) => _update(() => _duration = v)))
        ..add(player.streams.error.listen((e) => _update(() => _error = '$e')));
      setState(() => _player = player);
      await player.open(Media(url.toString()));
    } catch (e, st) {
      appLogger.e('Storage preview failed to open ${widget.entry.path}', error: e, stackTrace: st);
      _update(() => _error = e is StorageException ? e.message : '$e');
    }
  }

  void _update(VoidCallback change) {
    if (mounted) setState(change);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    final player = _player;
    if (player != null) {
      unawaited(player.dispose().catchError((Object e) => appLogger.w('Storage preview player dispose failed: $e')));
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final player = _player;
    final error = _error;
    final totalMs = _duration.inMilliseconds.toDouble();
    final positionMs = (_scrubbing ?? _position.inMilliseconds.toDouble()).clamp(0.0, totalMs > 0 ? totalMs : 0.0);
    return Scaffold(
      // Some platforms composite the video beneath the Flutter surface.
      backgroundColor: Colors.transparent,
      appBar: AppBar(title: Text(widget.entry.name)),
      body: Column(
        children: [
          Expanded(
            child: error != null
                ? ColoredBox(
                    color: Colors.black,
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          error,
                          style: const TextStyle(color: Colors.white),
                          textAlign: TextAlign.center,
                        ),
                      ),
                    ),
                  )
                : player == null
                ? const ColoredBox(
                    color: Colors.black,
                    child: Center(child: CircularProgressIndicator()),
                  )
                : Video(player: player),
          ),
          Material(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    tooltip: _playing ? t.common.pause : t.common.play,
                    icon: AppIcon(_playing ? Symbols.pause_rounded : Symbols.play_arrow_rounded),
                    onPressed: player == null ? null : () => unawaited(player.playOrPause()),
                  ),
                  Text(formatDurationTimestamp(Duration(milliseconds: positionMs.round()))),
                  Expanded(
                    child: Slider(
                      max: totalMs > 0 ? totalMs : 1,
                      value: positionMs,
                      onChanged: player == null || totalMs <= 0 ? null : (v) => setState(() => _scrubbing = v),
                      onChangeEnd: player == null
                          ? null
                          : (v) {
                              setState(() => _scrubbing = null);
                              unawaited(player.seek(Duration(milliseconds: v.round())));
                            },
                    ),
                  ),
                  Text(formatDurationTimestamp(_duration)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
