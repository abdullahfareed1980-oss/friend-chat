import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/rest_client.dart';
import '../state/app_session.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';
import 'welcome_screen.dart';

/// ---------------------------------------------------------------------------
/// OTP verification. Six boxes, one hidden field, auto-submit when full.
/// The code is single use, expires in 10 minutes, and is verified by your own
/// server - not by Twilio, Firebase or anyone else.
/// ---------------------------------------------------------------------------

class OtpScreen extends StatefulWidget {
  const OtpScreen({
    super.key,
    required this.client,
    required this.challenge,
    required this.phoneLabel,
  });

  final ApiClient client;
  final OtpChallenge challenge;
  final String phoneLabel;

  @override
  State<OtpScreen> createState() => _OtpScreenState();
}

class _OtpScreenState extends State<OtpScreen> {
  final TextEditingController _code = TextEditingController();
  final FocusNode _focus = FocusNode();

  late OtpChallenge _challenge = widget.challenge;
  late int _resendIn = widget.challenge.resendAfterSeconds;
  Timer? _ticker;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _startTicker();
    WidgetsBinding.instance.addPostFrameCallback((_) => _focus.requestFocus());
    if (_challenge.devCode != null) {
      // Server is running with OTP_DEBUG=true (LAN testing only).
      _code.text = _challenge.devCode!;
    }
  }

  void _startTicker() {
    _ticker?.cancel();
    if (_resendIn <= 0) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) return;
      setState(() => _resendIn--);
      if (_resendIn <= 0) timer.cancel();
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    _code.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _verify() async {
    final code = _code.text.replaceAll(RegExp(r'\D'), '');
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6 digits from your server terminal.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final session = context.read<AppSession>();

    try {
      final result = await widget.client.verifyOtp(
        challengeId: _challenge.challengeId,
        code: code,
        device: {
          'id': session.deviceId,
          'name': session.deviceName,
          'platform': session.devicePlatform,
        },
      );

      if (!mounted) return;
      await session.signIn(result);
      if (!mounted) return;
      Navigator.of(context).popUntil((route) => route.isFirst);
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (err.code) {
          'invalid_code' => 'That code is not right. ${err.detail ?? ''}'.trim(),
          'code_expired' => 'That code expired. Request a new one.',
          'challenge_used' => 'That code was already used. Request a new one.',
          'too_many_attempts' => 'Too many attempts. Request a new code.',
          'phone_not_enrolled' => 'This number is no longer enrolled on the server.',
          _ => 'Verification failed (${err.code}).',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not reach your server. Check the connection.';
      });
    }
  }

  Future<void> _resend() async {
    setState(() {
      _error = null;
      _busy = true;
    });
    try {
      final next = await widget.client.requestOtp(
        countryCode: _challenge.countryCode,
        phone: _challenge.phone.substring(_challenge.countryCode.replaceAll('+', '').length),
      );
      if (!mounted) return;
      setState(() {
        _challenge = next;
        _resendIn = next.resendAfterSeconds;
        _busy = false;
        _code.clear();
      });
      _startTicker();
      _focus.requestFocus();
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not send a new code yet.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final digits = _code.text.replaceAll(RegExp(r'\D'), '');

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline_rounded, size: 20),
            onPressed: () => showOtpDeliveryHint(context),
          ),
        ],
      ),
      body: FcScaffold(
        padded: true,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: FcSpace.md),
            const Text('Enter the\n6-digit code', style: FcText.display),
            const SizedBox(height: FcSpace.sm),
            Text(
              'Sent to ${widget.phoneLabel} — printed in your server terminal, not by SMS.',
              style: FcText.muted.copyWith(height: 1.5),
            ),
            const SizedBox(height: FcSpace.xl),

            // Hidden field + six painted boxes.
            Stack(
              children: [
                Opacity(
                  opacity: 0.01,
                  child: TextField(
                    controller: _code,
                    focusNode: _focus,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
                    onChanged: (value) {
                      setState(() {});
                      if (value.replaceAll(RegExp(r'\D'), '').length == 6) _verify();
                    },
                  ),
                ),
                GestureDetector(
                  onTap: _focus.requestFocus,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: List.generate(6, (index) {
                      final filled = index < digits.length;
                      final active = index == digits.length;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 160),
                        width: 48,
                        height: 60,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: filled ? FcColors.surfaceGlass : FcColors.surfaceHigh,
                          borderRadius: BorderRadius.circular(FcRadius.md),
                          border: Border.all(
                            color: filled
                                ? FcColors.indigo.withOpacity(0.7)
                                : active
                                    ? FcColors.mint.withOpacity(0.6)
                                    : FcColors.divider,
                            width: active ? 1.6 : 1,
                          ),
                          boxShadow: active
                              ? [BoxShadow(color: FcColors.mint.withOpacity(0.15), blurRadius: 14)]
                              : null,
                        ),
                        child: Text(
                          filled ? digits[index] : '',
                          style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w700, color: FcColors.text),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),

            if (_challenge.devCode != null) ...[
              const SizedBox(height: FcSpace.md),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: FcColors.warning.withOpacity(0.10),
                  borderRadius: BorderRadius.circular(FcRadius.sm),
                  border: Border.all(color: FcColors.warning.withOpacity(0.35)),
                ),
                child: Text(
                  'Dev mode: your server returned ${_challenge.devCode}. Turn OTP_DEBUG off in production.',
                  style: const TextStyle(fontSize: 11.5, color: FcColors.warning, height: 1.4),
                ),
              ),
            ],

            if (_error != null) ...[
              const SizedBox(height: FcSpace.md),
              Text(_error!, style: const TextStyle(color: FcColors.danger, fontSize: 12.5, height: 1.4)),
            ],

            const SizedBox(height: FcSpace.lg),
            GradientButton(label: 'Verify', loading: _busy, onPressed: _verify),
            const SizedBox(height: FcSpace.md),
            Center(
              child: _resendIn > 0
                  ? Text('Resend code in ${_resendIn}s', style: FcText.caption)
                  : TextButton.icon(
                      onPressed: _busy ? null : _resend,
                      icon: const Icon(Icons.refresh_rounded, size: 17),
                      label: const Text('Resend code'),
                    ),
            ),
            const Spacer(),
            Row(
              children: [
                const Icon(Icons.lock_rounded, size: 13, color: FcColors.mint),
                const SizedBox(width: 7),
                Expanded(
                  child: Text(
                    'The code is single use and expires in 10 minutes.',
                    style: FcText.caption,
                  ),
                ),
              ],
            ),
            const SizedBox(height: FcSpace.md),
          ],
        ),
      ),
    );
  }
}