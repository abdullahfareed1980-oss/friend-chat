import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/rest_client.dart';
import '../state/app_session.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';
import '../widgets/friend_chat_logo.dart';

/// ---------------------------------------------------------------------------
/// Two-Step Verification Password Setup.
///
/// Once Email OTP is verified, the user establishes a permanent Account Password
/// binding their phone number and Gmail address in SQLite.
/// ---------------------------------------------------------------------------

class SetPasswordScreen extends StatefulWidget {
  const SetPasswordScreen({
    super.key,
    required this.client,
    required this.challengeId,
    required this.phoneLabel,
    this.email,
  });

  final ApiClient client;
  final String challengeId;
  final String phoneLabel;
  final String? email;

  @override
  State<SetPasswordScreen> createState() => _SetPasswordScreenState();
}

class _SetPasswordScreenState extends State<SetPasswordScreen> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirmPassword = TextEditingController();

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final password = _password.text;
    final confirm = _confirmPassword.text;
    final name = _name.text.trim();

    if (password.length < 6) {
      setState(() => _error = 'Password must be at least 6 characters.');
      return;
    }

    if (password != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final session = context.read<AppSession>();

    try {
      final loginResult = await widget.client.setPassword(
        challengeId: widget.challengeId,
        password: password,
        displayName: name.isNotEmpty ? name : null,
        device: {
          'id': session.deviceId,
          'name': session.deviceName,
          'platform': session.devicePlatform,
        },
      );

      if (!mounted) return;
      await session.signIn(loginResult);
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = err.detail ?? 'Failed to set password (${err.code}).';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not reach the server. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const FriendChatWordmark(markSize: 28, fontSize: 17),
      ),
      body: FcScaffold(
        padded: true,
        child: ListView(
          padding: const EdgeInsets.only(top: FcSpace.lg, bottom: FcSpace.xl),
          children: [
            const Icon(Icons.lock_person_rounded, size: 54, color: FcColors.mint),
            const SizedBox(height: FcSpace.md),
            const Text('Two-Step\nVerification', style: FcText.display),
            const SizedBox(height: FcSpace.sm),
            Text(
              'Create a secure password for ${widget.phoneLabel}. '
              'This permanently binds your phone number to ${widget.email ?? 'your Gmail'} in your self-hosted database.',
              style: FcText.muted.copyWith(height: 1.5),
            ),
            const SizedBox(height: FcSpace.xl),

            // Display Name field
            TextField(
              controller: _name,
              textCapitalization: TextCapitalization.words,
              style: const TextStyle(fontSize: 16),
              decoration: const InputDecoration(
                prefixIcon: Icon(Icons.person_outline_rounded, size: 20, color: FcColors.textMuted),
                labelText: 'Your display name (optional)',
                hintText: 'e.g. Alex Morgan',
              ),
            ),
            const SizedBox(height: 14),

            // Password field
            TextField(
              controller: _password,
              obscureText: _obscurePassword,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20, color: FcColors.textMuted),
                labelText: 'Account password (minimum 6 characters)',
                hintText: '••••••••',
                suffixIcon: IconButton(
                  icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
                  onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // Confirm Password field
            TextField(
              controller: _confirmPassword,
              obscureText: _obscureConfirm,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.lock_reset_rounded, size: 20, color: FcColors.textMuted),
                labelText: 'Confirm account password',
                hintText: '••••••••',
                suffixIcon: IconButton(
                  icon: Icon(_obscureConfirm ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
                  onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
                ),
              ),
              onSubmitted: (_) => _submit(),
            ),

            if (_error != null) ...[
              const SizedBox(height: 14),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: FcColors.danger.withOpacity(0.12),
                  borderRadius: BorderRadius.circular(FcRadius.md),
                  border: Border.all(color: FcColors.danger.withOpacity(0.4)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Icon(Icons.error_outline_rounded, size: 18, color: FcColors.danger),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _error!,
                        style: const TextStyle(color: FcColors.danger, fontSize: 13, height: 1.4, fontWeight: FontWeight.w500),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const SizedBox(height: FcSpace.xl),
            GradientButton(
              label: 'Set Password & Complete',
              icon: Icons.check_circle_outline_rounded,
              loading: _busy,
              onPressed: _submit,
            ),
            const SizedBox(height: FcSpace.lg),

            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: FcColors.surfaceHigh,
                borderRadius: BorderRadius.circular(FcRadius.md),
                border: Border.all(color: FcColors.divider),
              ),
              child: Row(
                children: [
                  const Icon(Icons.shield_rounded, size: 18, color: FcColors.mint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Account Locking Active: This password and email pair protects your account against SIM swapping and unauthorized access.',
                      style: FcText.caption.copyWith(height: 1.4),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
