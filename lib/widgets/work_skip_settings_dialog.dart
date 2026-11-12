import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../database/app_database.dart';
import '../focus/focusable_text_field.dart';
import '../i18n/strings.g.dart';
import '../media/ids.dart';
import '../media/media_item.dart';
import '../media/media_kind.dart';
import '../media/media_server_client.dart';
import '../media/work_identity.dart';
import '../media/work_skip_settings.dart';
import '../services/work_skip_settings_store.dart';
import '../utils/dialogs.dart';
import '../utils/provider_extensions.dart';
import 'dialog_action_button.dart';
import 'focusable_list_tile.dart';

Future<WorkSkipSettings?> showWorkSkipSettingsDialog(
  BuildContext context,
  MediaItem item, {
  Duration? duration,
  Duration? clicked,
}) {
  final store = WorkSkipSettingsStore(context.read<AppDatabase>());
  final client = context.tryGetMediaClientForServer(serverIdOrNull(item.serverId));
  return showScopedDialog<WorkSkipSettings>(
    context: context,
    builder: (_) =>
        WorkSkipSettingsDialog(item: item, store: store, client: client, duration: duration, clicked: clicked),
  );
}

class WorkSkipSettingsDialog extends StatefulWidget {
  const WorkSkipSettingsDialog({
    super.key,
    required this.item,
    required this.store,
    this.client,
    this.duration,
    this.clicked,
  });
  final MediaItem item;
  final WorkSkipSettingsStore store;
  final MediaServerClient? client;
  final Duration? duration;
  final Duration? clicked;

  @override
  State<WorkSkipSettingsDialog> createState() => _WorkSkipSettingsDialogState();
}

class _WorkSkipSettingsDialogState extends State<WorkSkipSettingsDialog> {
  WorkIdentity? _work;
  bool _loading = true;
  bool _saving = false;
  bool _intro = false;
  bool _credits = false;
  String? _error;
  final _start = TextEditingController(text: '00:00');
  final _end = TextEditingController(text: '00:00');
  final _length = TextEditingController(text: '00:00');
  final _resume = TextEditingController(text: '00:00');

  @override
  void initState() {
    super.initState();
    _load();
  }

  static String _time(int ms) =>
      '${(ms ~/ 60000).toString().padLeft(2, '0')}:${(ms ~/ 1000 % 60).toString().padLeft(2, '0')}';
  static int? _parse(String value) {
    final match = RegExp(r'^(\d{1,5}):([0-5]\d)$').firstMatch(value.trim());
    return match == null ? null : (int.parse(match[1]!) * 60 + int.parse(match[2]!)) * 1000;
  }

  Future<void> _load() async {
    try {
      final work = await widget.store.resolve(widget.item, widget.client);
      if (!mounted) return;
      if (work == null) {
        setState(() {
          _loading = false;
          _error = t.workSkip.unavailable;
        });
        return;
      }
      var rules = await widget.store.read(work);
      if (!mounted) return;
      if (widget.clicked != null && widget.duration != null && widget.duration! > Duration.zero) {
        rules = rules.prefill(widget.clicked!, widget.duration!);
      }
      setState(() {
        _work = work;
        _loading = false;
        _intro = rules.introEnabled;
        _credits = rules.creditsEnabled;
        _start.text = _time(rules.introStartMs);
        _end.text = _time(rules.introEndMs);
        _length.text = _time(rules.creditsDurationMs);
        _resume.text = _time(rules.creditsResumeBeforeEndMs);
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _loading = false;
          _error = t.workSkip.loadFailed;
        });
      }
    }
  }

  Future<void> _save() async {
    if (_saving || _work == null) return;
    final start = _parse(_start.text),
        end = _parse(_end.text),
        length = _parse(_length.text),
        resume = _parse(_resume.text);
    final rules = WorkSkipSettings(
      introEnabled: _intro,
      introStartMs: start ?? 0,
      introEndMs: end ?? 0,
      creditsEnabled: _credits,
      creditsDurationMs: length ?? 0,
      creditsResumeBeforeEndMs: resume ?? 0,
    );
    if ((_intro && (start == null || end == null)) ||
        (_credits && (length == null || resume == null)) ||
        !rules.validFor(widget.duration?.inMilliseconds)) {
      setState(() => _error = t.workSkip.invalid);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await widget.store.save(_work!, rules);
      if (mounted) Navigator.of(context).pop(rules);
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _error = t.workSkip.saveFailed;
        });
      }
    }
  }

  @override
  void dispose() {
    for (final c in [_start, _end, _length, _resume]) {
      c.dispose();
    }
    super.dispose();
  }

  Widget _field(String key, String label, TextEditingController controller, bool enabled) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: FocusableTextField(
      key: ValueKey(key),
      controller: controller,
      enabled: enabled && !_saving,
      keyboardType: TextInputType.datetime,
      decoration: InputDecoration(labelText: label, hintText: t.workSkip.timeHint, border: const OutlineInputBorder()),
    ),
  );

  Widget _toggle(String label, bool value, Color color, VoidCallback toggle) => FocusableListTile(
    contentPadding: EdgeInsets.zero,
    title: Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
    leading: Icon(Icons.circle, color: color, size: 12),
    trailing: Icon(value ? Icons.check_circle : Icons.radio_button_unchecked),
    enabled: !_saving,
    onTap: toggle,
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: Text(t.workSkip.title),
      content: SizedBox(
        width: 520,
        child: _loading
            ? const SizedBox(height: 120, child: Center(child: CircularProgressIndicator()))
            : SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.item.kind == MediaKind.movie
                          ? widget.item.title ?? ''
                          : widget.item.grandparentTitle ?? widget.item.parentTitle ?? widget.item.title ?? '',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const SizedBox(height: 6),
                    Text(widget.item.kind == MediaKind.movie ? t.workSkip.scopeMovie : t.workSkip.scopeShow),
                    if (_work != null) ...[
                      const SizedBox(height: 16),
                      _toggle(t.workSkip.intro, _intro, Colors.lightBlueAccent, () => setState(() => _intro = !_intro)),
                      Row(
                        children: [
                          Expanded(child: _field('intro-start', t.workSkip.introStart, _start, _intro)),
                          const SizedBox(width: 12),
                          Expanded(child: _field('intro-end', t.workSkip.introEnd, _end, _intro)),
                        ],
                      ),
                      const SizedBox(height: 16),
                      const Divider(),
                      _toggle(t.workSkip.credits, _credits, Colors.amber, () => setState(() => _credits = !_credits)),
                      Row(
                        children: [
                          Expanded(child: _field('credits-length', t.workSkip.creditsDuration, _length, _credits)),
                          const SizedBox(width: 12),
                          Expanded(child: _field('credits-resume', t.workSkip.resumeBeforeEnd, _resume, _credits)),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(t.workSkip.resumeHint, style: Theme.of(context).textTheme.bodySmall),
                      const SizedBox(height: 20),
                      Text(t.workSkip.behavior, style: Theme.of(context).textTheme.bodySmall),
                    ],
                    if (_error != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                      ),
                  ],
                ),
              ),
      ),
      actions: [
        DialogActionButton(onPressed: _saving ? null : () => Navigator.of(context).pop(), label: t.common.cancel),
        if (_work != null) DialogActionButton(onPressed: _saving ? null : _save, label: t.common.save, isPrimary: true),
      ],
    ),
  );
}
