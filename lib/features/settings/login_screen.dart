import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import '../../data/services/auth_service.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  static const int _resendSeconds = 60;
  static const int _minOtpDigits = 6;
  static const int _maxOtpDigits = 8;

  final _emailController = TextEditingController();
  final _tokenController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _codeSent = false;
  bool _loading = false;
  String? _error;
  String _submittedEmail = '';

  Timer? _resendTimer;
  int _countdown = 0;

  @override
  void dispose() {
    _resendTimer?.cancel();
    _emailController.dispose();
    _tokenController.dispose();
    super.dispose();
  }

  void _startCountdown() {
    _resendTimer?.cancel();
    setState(() => _countdown = _resendSeconds);
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _countdown--);
      if (_countdown <= 0) t.cancel();
    });
  }

  /// Maps a raw exception to a user-facing localized message.
  String _mapError(Object e) {
    final s = ref.read(stringsProvider);
    if (e is BackendNotConfiguredException) return s.loginErrorNotConfigured;
    final msg = e.toString().toLowerCase();
    if (e is AuthApiException) {
      if (msg.contains('email') && msg.contains('invalid')) return s.emailInvalid;
      if (msg.contains('otp') || msg.contains('token') || msg.contains('invalid') || msg.contains('expired')) {
        return s.loginErrorOtpInvalid;
      }
      return s.loginErrorGeneric;
    }
    if (msg.contains('socket') || msg.contains('timeout')) return s.loginErrorNetwork;
    return e.toString();
  }

  Future<void> _sendCode() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await ref
          .read(authControllerProvider.notifier)
          .sendOtp(_emailController.text.trim());
      setState(() {
        _codeSent = true;
        _submittedEmail = _emailController.text.trim();
      });
      _startCountdown();
    } catch (e) {
      setState(() => _error = _mapError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _verifyCode() async {
    final token = _tokenController.text.replaceAll(RegExp(r'\s+'), '');
    if (token.length < _minOtpDigits) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      await ref
          .read(authControllerProvider.notifier)
          .verifyOtp(_submittedEmail, token);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      setState(() => _error = _mapError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _resend() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(authControllerProvider.notifier).sendOtp(_submittedEmail);
      _startCountdown();
    } catch (e) {
      setState(() => _error = _mapError(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(title: Text(s.accountLogin)),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 400),
            child: Form(
              key: _formKey,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Icon(
                    Icons.mail_outline_rounded,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    s.accountLogin,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    _codeSent
                        ? '${s.codeSentPrefix} $_submittedEmail'
                        : s.loginDesc,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                  ),
                  const SizedBox(height: 32),
                  if (!_codeSent) ...[
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      textInputAction: TextInputAction.done,
                      decoration: InputDecoration(
                        labelText: s.emailLabel,
                        prefixIcon: const Icon(Icons.email_rounded),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return s.emailRequired;
                        }
                        final emailRegex = RegExp(
                          r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                        );
                        if (!emailRegex.hasMatch(v.trim())) {
                          return s.emailInvalid;
                        }
                        return null;
                      },
                      onFieldSubmitted: (_) => _sendCode(),
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _loading ? null : _sendCode,
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(s.sendCode),
                    ),
                  ],
                  if (_codeSent) ...[
                    TextFormField(
                      controller: _tokenController,
                      keyboardType: TextInputType.number,
                      maxLength: _maxOtpDigits,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: 24, letterSpacing: 6),
                      decoration: const InputDecoration(counterText: ''),
                      onChanged: (v) {
                        if (v.length == _maxOtpDigits) {
                          _verifyCode();
                        }
                      },
                    ),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _loading ? null : _verifyCode,
                      child: _loading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : Text(s.verifyCode),
                    ),
                    const SizedBox(height: 8),
                    if (_countdown > 0)
                      Text(
                        s.resendCountdown.replaceAll(
                          '{}',
                          _countdown.toString(),
                        ),
                        textAlign: TextAlign.center,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurface.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      )
                    else
                      TextButton(
                        onPressed: _loading ? null : _resend,
                        child: Text(s.resendCode),
                      ),
                    const SizedBox(height: 4),
                    TextButton(
                      onPressed: _loading
                          ? null
                          : () {
                              _resendTimer?.cancel();
                              setState(() {
                                _codeSent = false;
                                _error = null;
                                _countdown = 0;
                                _tokenController.clear();
                              });
                            },
                      child: Text(s.changeEmail),
                    ),
                  ],
                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: theme.colorScheme.errorContainer,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        _error!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onErrorContainer,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
