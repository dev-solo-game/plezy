import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:provider/provider.dart';

import '../../focus/focusable_button.dart';
import '../../focus/focusable_text_field.dart';
import '../../focus/key_event_utils.dart';
import '../../i18n/strings.g.dart';
import '../../session/app_session_controller.dart';
import '../../session/app_session_models.dart';
import '../../widgets/app_icon.dart';

class SelfHostedLoginScreen extends StatefulWidget {
  const SelfHostedLoginScreen({super.key, this.initialServerUrl});

  final String? initialServerUrl;

  @override
  State<SelfHostedLoginScreen> createState() => _SelfHostedLoginScreenState();
}

class _SelfHostedLoginScreenState extends State<SelfHostedLoginScreen> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _serverController = TextEditingController(text: widget.initialServerUrl ?? '');
  final TextEditingController _usernameController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();

  bool _obscurePassword = true;
  bool _testing = false;
  bool _submitting = false;
  ({bool ok, String message})? _probeStatus;
  String? _errorMessage;

  @override
  void dispose() {
    _serverController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  String _localizeAuthError(SelfHostedAuthException e) => switch (e.kind) {
    SelfHostedAuthErrorKind.invalidUrl => t.session.errInvalidUrl,
    SelfHostedAuthErrorKind.uninitializedServer => t.session.errUninitializedServer,
    SelfHostedAuthErrorKind.invalidCredentials => t.session.errInvalidCredentials,
    SelfHostedAuthErrorKind.network => t.session.errNetwork(error: e.message),
    SelfHostedAuthErrorKind.serverError => t.session.errServer(error: e.message),
  };

  Future<void> _testConnection() async {
    if (_testing || _submitting) return;
    final rawUrl = _serverController.text.trim();
    if (rawUrl.isEmpty) {
      setState(() {
        _probeStatus = (ok: false, message: t.session.errInvalidUrl);
      });
      return;
    }

    final session = context.read<AppSessionController?>();
    if (session == null) return;

    setState(() {
      _testing = true;
      _probeStatus = null;
      _errorMessage = null;
    });

    try {
      final info = await session.probeSelfHostedServer(rawUrl);
      if (!mounted) return;
      _serverController.text = info.serverUrl;
      if (!info.initialized) {
        setState(() {
          _probeStatus = (ok: false, message: t.session.errUninitializedServer);
        });
      } else {
        final msg = info.serverName.isNotEmpty
            ? t.session.serverConnected(name: info.serverName)
            : t.session.serverConnectedUnnamed;
        setState(() {
          _probeStatus = (ok: true, message: msg);
        });
      }
    } on SelfHostedAuthException catch (e) {
      if (!mounted) return;
      setState(() {
        _probeStatus = (ok: false, message: _localizeAuthError(e));
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _probeStatus = (ok: false, message: t.session.errNetwork(error: '$e'));
      });
    } finally {
      if (mounted) setState(() => _testing = false);
    }
  }

  Future<void> _submit() async {
    if (_submitting || !(_formKey.currentState?.validate() ?? false)) return;
    final session = context.read<AppSessionController?>();
    if (session == null) return;

    setState(() {
      _submitting = true;
      _errorMessage = null;
    });

    try {
      await session.loginSelfHosted(
        serverUrl: _serverController.text.trim(),
        username: _usernameController.text.trim(),
        password: _passwordController.text,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on SelfHostedAuthException catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = _localizeAuthError(e));
    } catch (e) {
      if (!mounted) return;
      setState(() => _errorMessage = t.session.errNetwork(error: '$e'));
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final busy = _submitting || _testing;

    return Focus(
      canRequestFocus: false,
      onKeyEvent: (_, event) => handleBackKeyNavigation(context, event),
      child: Scaffold(
        appBar: AppBar(title: Text(t.session.selfHostedLoginTitle)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 460),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: Form(
                key: _formKey,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    FocusableTextFormField(
                      controller: _serverController,
                      enabled: !_submitting,
                      keyboardType: TextInputType.url,
                      textInputAction: TextInputAction.next,
                      autofocus: true,
                      tvTextInputAutoOpenBehavior: deferredUrlFieldAutoOpen,
                      decoration: InputDecoration(
                        labelText: t.session.serverUrlLabel,
                        hintText: t.session.serverUrlHint,
                        prefixIcon: const AppIcon(Symbols.dns_rounded),
                        border: const OutlineInputBorder(),
                      ),
                      validator: (value) {
                        final raw = value?.trim() ?? '';
                        if (raw.isEmpty) return t.session.errInvalidUrl;
                        final normalized = SelfHostedSession.normalizeServerUrl(raw);
                        final uri = Uri.tryParse(normalized);
                        if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
                          return t.session.errInvalidUrl;
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 10),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: FocusableButton(
                        child: OutlinedButton.icon(
                          onPressed: busy ? null : _testConnection,
                          icon: _testing
                              ? const SizedBox.square(
                                  dimension: 16,
                                  child: CircularProgressIndicator(strokeWidth: 2),
                                )
                              : const AppIcon(Symbols.network_check_rounded, size: 18),
                          label: Text(_testing ? t.session.testingServer : t.session.testServer),
                        ),
                      ),
                    ),
                    if (_probeStatus case final status?) ...[
                      const SizedBox(height: 10),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                        decoration: BoxDecoration(
                          color: status.ok ? colorScheme.primaryContainer : colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            AppIcon(
                              status.ok ? Symbols.check_circle_rounded : Symbols.error_outline_rounded,
                              size: 18,
                              color: status.ok ? colorScheme.onPrimaryContainer : colorScheme.onErrorContainer,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                status.message,
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: status.ok ? colorScheme.onPrimaryContainer : colorScheme.onErrorContainer,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FocusableTextFormField(
                      controller: _usernameController,
                      enabled: !_submitting,
                      textInputAction: TextInputAction.next,
                      decoration: InputDecoration(
                        labelText: t.session.usernameLabel,
                        prefixIcon: const AppIcon(Symbols.person_rounded),
                        border: const OutlineInputBorder(),
                      ),
                      validator: (value) => (value == null || value.trim().isEmpty) ? t.session.errRequiredField : null,
                    ),
                    const SizedBox(height: 14),
                    FocusableTextFormField(
                      controller: _passwordController,
                      enabled: !_submitting,
                      obscureText: _obscurePassword,
                      textInputAction: TextInputAction.done,
                      onFieldSubmitted: (_) => unawaited(_submit()),
                      decoration: InputDecoration(
                        labelText: t.session.passwordLabel,
                        prefixIcon: const AppIcon(Symbols.lock_rounded),
                        border: const OutlineInputBorder(),
                        suffixIcon: IconButton(
                          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                          icon: AppIcon(_obscurePassword ? Symbols.visibility_rounded : Symbols.visibility_off_rounded),
                        ),
                      ),
                      validator: (value) => (value == null || value.isEmpty) ? t.session.errRequiredField : null,
                    ),
                    const SizedBox(height: 12),
                    Text(
                      t.session.archiveHint,
                      style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onSurfaceVariant),
                    ),
                    if (_errorMessage != null) ...[
                      const SizedBox(height: 14),
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          color: colorScheme.errorContainer,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          _errorMessage!,
                          style: theme.textTheme.bodySmall?.copyWith(color: colorScheme.onErrorContainer),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    FocusableButton(
                      onPressed: _submitting ? null : () => unawaited(_submit()),
                      child: FilledButton(
                        onPressed: _submitting ? null : () => unawaited(_submit()),
                        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 14)),
                        child: _submitting
                            ? const SizedBox.square(
                                dimension: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : Text(t.session.signInButton),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
