import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../data/rest_client.dart';
import '../state/app_session.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';
import '../widgets/friend_chat_logo.dart';
import 'phone_screen.dart';
import 'server_setup_screen.dart';

/// ---------------------------------------------------------------------------
/// First launch. Sets the tone: private, two people, no cloud in the middle.
/// ---------------------------------------------------------------------------

class WelcomeScreen extends StatelessWidget {
  const WelcomeScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();

    return Scaffold(
      body: AuroraBackdrop(
        child: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: FcSpace.lg),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: FcSpace.lg),
                const FriendChatWordmark(markSize: 38, fontSize: 20),
                const Spacer(),
                const Center(child: FriendChatLogo(size: 132)),
                const SizedBox(height: FcSpace.xl),
                const Text('A private line\nbetween two people.', style: FcText.display),
                const SizedBox(height: FcSpace.md),
                Text(
                  'No cloud, no push servers, no analytics. Your messages travel '
                  'straight to a server you own, sealed end to end.',
                  style: FcText.muted.copyWith(fontSize: 14.5, height: 1.5),
                ),
                const SizedBox(height: FcSpace.lg),
                const _Feature(
                  icon: Icons.lock_rounded,
                  title: 'End-to-end encrypted',
                  body: 'Keys never leave the two devices.',
                ),
                const _Feature(
                  icon: Icons.dns_rounded,
                  title: 'Your own server',
                  body: 'A Raspberry Pi at home or your own VPS.',
                ),
                const _Feature(
                  icon: Icons.notifications_off_rounded,
                  title: 'No FCM, no APNs',
                  body: 'Notifications come over your own socket.',
                ),
                const Spacer(),
                GradientButton(
                  label: session.endpoints.isEmpty ? 'Set up your server' : 'Continue',
                  icon: Icons.arrow_forward_rounded,
                  onPressed: () => _continue(context, session),
                ),
                const SizedBox(height: FcSpace.md),
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const PhoneScreen()),
                    ),
                    child: const Text('I already have an account'),
                  ),
                ),
                const SizedBox(height: FcSpace.sm),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _continue(BuildContext context, AppSession session) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => session.endpoints.isEmpty ? const ServerSetupScreen() : const PhoneScreen(),
      ),
    );
  }
}

class _Feature extends StatelessWidget {
  const _Feature({required this.icon, required this.title, required this.body});

  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: FcColors.mint.withOpacity(0.10),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: FcColors.mint.withOpacity(0.25)),
            ),
            child: Icon(icon, size: 18, color: FcColors.mintSoft),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14.5, color: FcColors.text)),
                const SizedBox(height: 2),
                Text(body, style: FcText.muted.copyWith(fontSize: 12.5)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Shared by the server screen and Settings: explains where the code comes from.
Future<void> showOtpDeliveryHint(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Where is my code?'),
      content: const Text(
        'Friend Chat has no SMS provider — that would mean a third party. '
        'Your 6-digit code is printed in the terminal running Friend Chat Server:\n\n'
        '  npm start                    (on a Pi or laptop)\n'
        '  docker compose logs -f server   (in Docker)\n\n'
        'It expires in 10 minutes and works once.',
        style: TextStyle(height: 1.45, fontSize: 13.5, color: FcColors.textMuted),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.of(context).pop(), child: const Text('Got it')),
      ],
    ),
  );
}

/// Convenience for onboarding screens.
Future<ApiClient?> requireOnboardingClient(BuildContext context, AppSession session) async {
  final client = await session.onboardingClient();
  if (client == null && context.mounted) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No server reachable. Check the address and your Wi-Fi.')),
    );
  }
  return client;
}