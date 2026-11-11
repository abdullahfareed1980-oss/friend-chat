import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../data/rest_client.dart';
import '../state/app_session.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';
import '../widgets/friend_chat_logo.dart';
import 'otp_screen.dart';
import 'welcome_screen.dart';

/// ---------------------------------------------------------------------------
/// Phone number entry, WhatsApp style: country code picker + national number.
///
/// Friend Chat only accepts the two numbers enrolled on your server, so this
/// screen can never create an arbitrary account.
/// ---------------------------------------------------------------------------

class Country {
  const Country(this.name, this.iso, this.dial, this.flag);
  final String name;
  final String iso;
  final String dial;
  final String flag;
}

const kCountries = <Country>[
  Country('Indonesia', 'ID', '+62', '🇮🇩'),
  Country('Australia', 'AU', '+61', '🇦🇺'),
  Country('Brazil', 'BR', '+55', '🇧🇷'),
  Country('Canada', 'CA', '+1', '🇨🇦'),
  Country('China', 'CN', '+86', '🇨🇳'),
  Country('Egypt', 'EG', '+20', '🇪🇬'),
  Country('France', 'FR', '+33', '🇫🇷'),
  Country('Germany', 'DE', '+49', '🇩🇪'),
  Country('India', 'IN', '+91', '🇮🇳'),
  Country('Ireland', 'IE', '+353', '🇮🇪'),
  Country('Italy', 'IT', '+39', '🇮🇹'),
  Country('Japan', 'JP', '+81', '🇯🇵'),
  Country('Kenya', 'KE', '+254', '🇰🇪'),
  Country('Malaysia', 'MY', '+60', '🇲🇾'),
  Country('Mexico', 'MX', '+52', '🇲🇽'),
  Country('Netherlands', 'NL', '+31', '🇳🇱'),
  Country('New Zealand', 'NZ', '+64', '🇳🇿'),
  Country('Nigeria', 'NG', '+234', '🇳🇬'),
  Country('Pakistan', 'PK', '+92', '🇵🇰'),
  Country('Philippines', 'PH', '+63', '🇵🇭'),
  Country('Poland', 'PL', '+48', '🇵🇱'),
  Country('Portugal', 'PT', '+351', '🇵🇹'),
  Country('Saudi Arabia', 'SA', '+966', '🇸🇦'),
  Country('Singapore', 'SG', '+65', '🇸🇬'),
  Country('South Africa', 'ZA', '+27', '🇿🇦'),
  Country('South Korea', 'KR', '+82', '🇰🇷'),
  Country('Spain', 'ES', '+34', '🇪🇸'),
  Country('Sweden', 'SE', '+46', '🇸🇪'),
  Country('Thailand', 'TH', '+66', '🇹🇭'),
  Country('Türkiye', 'TR', '+90', '🇹🇷'),
  Country('United Arab Emirates', 'AE', '+971', '🇦🇪'),
  Country('United Kingdom', 'GB', '+44', '🇬🇧'),
  Country('United States', 'US', '+1', '🇺🇸'),
  Country('Vietnam', 'VN', '+84', '🇻🇳'),
];

class PhoneScreen extends StatefulWidget {
  const PhoneScreen({super.key, this.initialCountry});

  final Country? initialCountry;

  @override
  State<PhoneScreen> createState() => _PhoneScreenState();
}

class _PhoneScreenState extends State<PhoneScreen> {
  late Country _country = widget.initialCountry ?? kCountries.first;
  final TextEditingController _phone = TextEditingController();
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  bool _showPasswordLogin = false;
  bool _obscurePassword = true;
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
    _email.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _pickCountry() async {
    final selected = await showModalBottomSheet<Country>(
      context: context,
      backgroundColor: FcColors.night,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(FcRadius.lg)),
      ),
      builder: (context) => _CountrySheet(selected: _country),
    );
    if (selected != null) setState(() => _country = selected);
  }

  Future<void> _requestCode() async {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 6) {
      setState(() => _error = 'Enter your full phone number.');
      return;
    }

    final email = _email.text.trim().toLowerCase();
    if (!email.contains('@') || !email.contains('.')) {
      setState(() => _error = 'Enter a valid Gmail or email address.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final session = context.read<AppSession>();
    final client = await requireOnboardingClient(context, session);
    if (client == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    try {
      final challenge = await client.requestOtp(
        countryCode: _country.dial,
        phone: digits,
        email: email,
      );
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OtpScreen(
            client: client,
            challenge: challenge,
            phoneLabel: '${_country.dial} $digits',
            email: email,
          ),
        ),
      );
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (err.code) {
          'account_locked' => 'Account locked to another email. This phone number is permanently paired with a different email address.',
          'email_already_bound' => 'This email is already linked to another phone number.',
          'invalid_email' => 'Please enter a valid Gmail address.',
          'phone_not_enrolled' => 'Registration is currently restricted on this server.',
          'resend_too_soon' => 'Wait a moment before requesting another code.',
          'invalid_country_code' || 'invalid_phone' => 'That phone number does not look right.',
          'too_many_requests' => 'Too many codes requested. Try again in an hour.',
          _ => err.detail ?? 'Could not request a code (${err.code}).',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not reach the server. Check your connection.';
      });
    }
  }

  Future<void> _loginWithPassword() async {
    final digits = _phone.text.replaceAll(RegExp(r'\D'), '');
    if (digits.length < 6) {
      setState(() => _error = 'Enter your registered phone number.');
      return;
    }

    final email = _email.text.trim().toLowerCase();
    final password = _password.text;
    if (password.isEmpty) {
      setState(() => _error = 'Enter your Two-Step Verification password.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    final session = context.read<AppSession>();
    final client = await requireOnboardingClient(context, session);
    if (client == null) {
      if (mounted) setState(() => _busy = false);
      return;
    }

    try {
      final result = await client.loginWithPassword(
        phone: digits,
        countryCode: _country.dial,
        email: email.isNotEmpty ? email : null,
        password: password,
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
          'account_locked' => 'Account locked to another email. This phone number is permanently paired with a different email address.',
          'invalid_credentials' => 'Incorrect password or phone number.',
          _ => err.detail ?? 'Login failed (${err.code}).',
        };
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = 'Could not reach the server. Check your connection.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded),
          onPressed: () => Navigator.of(context).maybePop(),
        ),
        title: const FriendChatWordmark(markSize: 28, fontSize: 17),
        actions: [
          IconButton(
            icon: const Icon(Icons.help_outline_rounded, size: 20),
            onPressed: () => showOtpDeliveryHint(context),
          ),
        ],
      ),
      body: FcScaffold(
        padded: true,
        child: ListView(
          padding: const EdgeInsets.only(top: FcSpace.lg, bottom: FcSpace.xl),
          children: [
            Text(
              _showPasswordLogin ? 'Sign in with\npassword' : 'Enter phone &\nGmail address',
              style: FcText.display,
            ),
            const SizedBox(height: FcSpace.sm),
            Text(
              _showPasswordLogin
                  ? 'Enter your registered phone number, paired Gmail, and Two-Step Verification password.'
                  : 'Zero manual seeding: register instantly or log in. A 6-digit OTP code will be sent directly to your Gmail via Nodemailer.',
              style: FcText.muted.copyWith(height: 1.5),
            ),
            const SizedBox(height: FcSpace.xl),

            // Country Picker + Phone Input
            Row(
              children: [
                InkWell(
                  onTap: _pickCountry,
                  borderRadius: BorderRadius.circular(FcRadius.md),
                  child: Container(
                    height: 58,
                    padding: const EdgeInsets.symmetric(horizontal: 14),
                    decoration: BoxDecoration(
                      color: FcColors.surfaceHigh,
                      borderRadius: BorderRadius.circular(FcRadius.md),
                      border: Border.all(color: FcColors.divider),
                    ),
                    child: Row(
                      children: [
                        Text(_country.flag, style: const TextStyle(fontSize: 20)),
                        const SizedBox(width: 8),
                        Text(_country.dial, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                        const SizedBox(width: 2),
                        const Icon(Icons.keyboard_arrow_down_rounded, size: 18, color: FcColors.textMuted),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: TextField(
                    controller: _phone,
                    keyboardType: TextInputType.phone,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(14)],
                    style: const TextStyle(fontSize: 18, letterSpacing: 0.6, fontWeight: FontWeight.w600),
                    decoration: const InputDecoration(
                      hintText: '812 3456 7890',
                      labelText: 'Phone number',
                      counterText: '',
                    ),
                    onSubmitted: (_) => _showPasswordLogin ? _loginWithPassword() : _requestCode(),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // Gmail Address Input
            TextField(
              controller: _email,
              keyboardType: TextInputType.emailAddress,
              style: const TextStyle(fontSize: 16),
              decoration: InputDecoration(
                prefixIcon: const Icon(Icons.email_outlined, size: 20, color: FcColors.textMuted),
                hintText: 'yourname@gmail.com',
                labelText: 'Gmail / Email address',
                helperText: 'Your account is permanently locked to this email for security',
                helperStyle: TextStyle(fontSize: 11.5, color: FcColors.textMuted.withOpacity(0.8)),
              ),
              onSubmitted: (_) => _showPasswordLogin ? _loginWithPassword() : _requestCode(),
            ),

            if (_showPasswordLogin) ...[
              const SizedBox(height: 14),
              TextField(
                controller: _password,
                obscureText: _obscurePassword,
                style: const TextStyle(fontSize: 16),
                decoration: InputDecoration(
                  prefixIcon: const Icon(Icons.lock_outline_rounded, size: 20, color: FcColors.textMuted),
                  labelText: 'Two-Step Verification Password',
                  hintText: '••••••••',
                  suffixIcon: IconButton(
                    icon: Icon(_obscurePassword ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 20),
                    onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
                  ),
                ),
                onSubmitted: (_) => _loginWithPassword(),
              ),
            ],

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
              label: _showPasswordLogin ? 'Log In' : 'Send Gmail OTP',
              icon: _showPasswordLogin ? Icons.login_rounded : Icons.mark_email_read_rounded,
              loading: _busy,
              onPressed: _showPasswordLogin ? _loginWithPassword : _requestCode,
            ),

            const SizedBox(height: FcSpace.md),
            Center(
              child: TextButton(
                onPressed: () => setState(() {
                  _showPasswordLogin = !_showPasswordLogin;
                  _error = null;
                }),
                child: Text(
                  _showPasswordLogin ? 'Verify with Email OTP instead' : 'Log in with Two-Step Password instead',
                  style: const TextStyle(color: FcColors.mint, fontWeight: FontWeight.w600),
                ),
              ),
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
                  const Icon(Icons.verified_user_outlined, size: 18, color: FcColors.mint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Strict Account Locking: Each phone number is bound to its verified Gmail. Unauthorized attempts with mismatched emails are rejected.',
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

class _CountrySheet extends StatefulWidget {
  const _CountrySheet({required this.selected});

  final Country selected;

  @override
  State<_CountrySheet> createState() => _CountrySheetState();
}

class _CountrySheetState extends State<_CountrySheet> {
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final filtered = kCountries
        .where((c) =>
            _query.isEmpty ||
            c.name.toLowerCase().contains(_query.toLowerCase()) ||
            c.dial.contains(_query))
        .toList();

    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          const SizedBox(height: 12),
          Container(
            width: 42,
            height: 4,
            decoration: BoxDecoration(color: FcColors.divider, borderRadius: BorderRadius.circular(2)),
          ),
          Padding(
            padding: const EdgeInsets.all(FcSpace.md),
            child: TextField(
              autofocus: false,
              onChanged: (value) => setState(() => _query = value),
              decoration: const InputDecoration(
                hintText: 'Search country',
                prefixIcon: Icon(Icons.search_rounded, size: 19),
              ),
            ),
          ),
          Expanded(
            child: ListView.builder(
              itemCount: filtered.length,
              itemBuilder: (context, index) {
                final country = filtered[index];
                final active = country.iso == widget.selected.iso;
                return ListTile(
                  onTap: () => Navigator.of(context).pop(country),
                  leading: Text(country.flag, style: const TextStyle(fontSize: 22)),
                  title: Text(country.name, style: const TextStyle(fontSize: 14.5)),
                  trailing: Text(
                    country.dial,
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: active ? FcColors.mint : FcColors.textMuted,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
