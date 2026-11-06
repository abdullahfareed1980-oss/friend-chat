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
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _phone.dispose();
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
      final challenge = await client.requestOtp(countryCode: _country.dial, phone: digits);
      if (!mounted) return;
      setState(() => _busy = false);
      await Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => OtpScreen(client: client, challenge: challenge, phoneLabel: '${_country.dial} $digits'),
        ),
      );
    } on ApiException catch (err) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = switch (err.code) {
          'phone_not_enrolled' => 'This number is not enrolled on your server. The owner adds numbers with `npm run seed -- --rotate`.',
          'resend_too_soon' => 'Wait a moment before requesting another code.',
          'invalid_country_code' || 'invalid_phone' => 'That phone number does not look right.',
          'too_many_requests' => 'Too many codes requested. Try again in an hour.',
          _ => 'Could not request a code (${err.code}).',
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
            const Text('Your phone\nnumber', style: FcText.display),
            const SizedBox(height: FcSpace.sm),
            Text(
              'Friend Chat verifies you with a code printed by your own server. '
              'No SMS provider ever sees your number.',
              style: FcText.muted.copyWith(height: 1.5),
            ),
            const SizedBox(height: FcSpace.xl),
            Row(
              children: [
                InkWell(
                  onTap: _pickCountry,
                  borderRadius: BorderRadius.circular(FcRadius.md),
                  child: Container(
                    height: 62,
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
                      counterText: '',
                    ),
                    onSubmitted: (_) => _requestCode(),
                  ),
                ),
              ],
            ),
            if (_error != null) ...[
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.info_outline_rounded, size: 15, color: FcColors.danger),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(_error!, style: const TextStyle(color: FcColors.danger, fontSize: 12.5, height: 1.4)),
                  ),
                ],
              ),
            ],
            const SizedBox(height: FcSpace.lg),
            GradientButton(label: 'Send code', icon: Icons.sms_rounded, loading: _busy, onPressed: _requestCode),
            const SizedBox(height: FcSpace.md),
            Center(
              child: Text(
                '${_country.name} · ${_country.dial}',
                style: FcText.caption,
              ),
            ),
            const SizedBox(height: FcSpace.xl),
            Row(
              children: [
                const Icon(Icons.shield_rounded, size: 14, color: FcColors.mint),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Your number is stored only in your own database, as the key for this account.',
                    style: FcText.caption.copyWith(height: 1.4),
                  ),
                ),
              ],
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
