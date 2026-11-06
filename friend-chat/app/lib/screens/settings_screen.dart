import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_session.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';
import '../widgets/friend_chat_logo.dart';

/// ---------------------------------------------------------------------------
/// Settings: who you are, where the server lives, what the encryption
/// fingerprint is, and how to get out.
/// ---------------------------------------------------------------------------

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _newEndpoint = TextEditingController();
  String? _safetyNumber;
  bool _showEndpointField = false;

  @override
  void initState() {
    super.initState();
    _loadSafetyNumber();
  }

  Future<void> _loadSafetyNumber() async {
    final value = await context.read<AppSession>().safetyNumber();
    if (mounted) setState(() => _safetyNumber = value);
  }

  @override
  void dispose() {
    _newEndpoint.dispose();
    super.dispose();
  }

  Future<void> _addEndpoint() async {
    final url = _newEndpoint.text.trim();
    if (url.isEmpty) return;
    final session = context.read<AppSession>();
    final health = await session.testServer(url);
    if (!mounted) return;

    if (health == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('That address did not answer.')),
      );
      return;
    }

    await session.addEndpoint(url);
    _newEndpoint.clear();
    if (!mounted) return;
    setState(() => _showEndpointField = false);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Address added')));
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final me = session.user;
    final peer = session.peer;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: FcScaffold(
        padded: true,
        child: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: FcSpace.xl),
          children: [
            FcCard(
              child: Row(
                children: [
                  FcAvatar(
                    name: me?.displayName ?? 'Me',
                    size: 54,
                    accentHex: me?.accentColor ?? '#4F46E5',
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          me?.businessName ?? me?.displayName ?? 'Signed in',
                          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          me?.phone == null ? 'No phone number' : '${me?.countryCode ?? ''} ${me?.phone ?? ''}',
                          style: FcText.muted.copyWith(fontSize: 12.5),
                        ),
                      ],
                    ),
                  ),
                  if (me?.isBusiness == true) const FcBadge(text: 'BUSINESS'),
                ],
              ),
            ),
            const SectionHeader(title: 'Server'),
            FcCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.dns_rounded, size: 16, color: FcColors.violetSoft),
                      const SizedBox(width: 8),
                      const Text('Addresses', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                      const Spacer(),
                      const ConnectionPill(compact: true),
                    ],
                  ),
                  const SizedBox(height: 10),
                  for (final endpoint in session.endpoints)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        children: [
                          Icon(
                            endpoint.isLocal ? Icons.wifi_rounded : Icons.public_rounded,
                            size: 14,
                            color: FcColors.textFaint,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              endpoint.url,
                              style: FcText.mono.copyWith(fontSize: 11.5),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          IconButton(
                            visualDensity: VisualDensity.compact,
                            icon: const Icon(Icons.close_rounded, size: 15, color: FcColors.textFaint),
                            onPressed: () => session.removeEndpoint(endpoint.url),
                          ),
                        ],
                      ),
                    ),
                  if (_showEndpointField)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: TextField(
                              controller: _newEndpoint,
                              decoration: const InputDecoration(hintText: 'https://chat.example.com'),
                            ),
                          ),
                          IconButton(onPressed: _addEndpoint, icon: const Icon(Icons.check_rounded, color: FcColors.mint)),
                        ],
                      ),
                    )
                  else
                    TextButton.icon(
                      onPressed: () => setState(() => _showEndpointField = true),
                      icon: const Icon(Icons.add_rounded, size: 17),
                      label: const Text('Add an address'),
                    ),
                ],
              ),
            ),
            const SectionHeader(title: 'Security'),
            FcCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.fingerprint_rounded, size: 17, color: FcColors.mint),
                      const SizedBox(width: 8),
                      const Text('Safety number', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_safetyNumber == null)
                    Text(
                      'Waiting for ${peer?.displayName ?? 'your friend'} to publish their key.',
                      style: FcText.caption.copyWith(height: 1.45),
                    )
                  else ...[
                    Text(
                      _safetyNumber!,
                      style: FcText.mono.copyWith(fontSize: 13, height: 1.7, letterSpacing: 1.4),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Compare this with ${peer?.displayName ?? 'your friend'} in person. '
                      'If both screens match, nobody has swapped a key in the middle.',
                      style: FcText.caption.copyWith(height: 1.45),
                    ),
                  ],
                ],
              ),
            ),
            const SectionHeader(title: 'Notifications'),
            FcCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.notifications_active_outlined, size: 16, color: FcColors.mint),
                      const SizedBox(width: 8),
                      const Text('Socket-based alerts', style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'No FCM or APNs. On Android a foreground service keeps the socket '
                    'alive and this app raises notifications locally. On Windows the app '
                    'must be running. On iOS the OS may suspend the socket in the '
                    'background — that is a platform limit, not a bug.',
                    style: FcText.caption.copyWith(height: 1.5),
                  ),
                ],
              ),
            ),
            const SectionHeader(title: 'This device'),
            FcCard(
              child: Column(
                children: [
                  _Row(label: 'Device', value: session.deviceName),
                  _Row(label: 'Platform', value: session.devicePlatform),
                  _Row(label: 'Conversation', value: session.conversationId?.substring(0, 8) ?? '—'),
                ],
              ),
            ),
            const SizedBox(height: FcSpace.lg),
            OutlinedButton.icon(
              onPressed: () async {
                await session.signOut();
                if (context.mounted) Navigator.of(context).popUntil((route) => route.isFirst);
              },
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(52),
                foregroundColor: FcColors.danger,
                side: BorderSide(color: FcColors.danger.withValues(alpha: 0.4)),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FcRadius.md)),
              ),
              icon: const Icon(Icons.logout_rounded, size: 18),
              label: const Text('Sign out of this device'),
            ),
            const SizedBox(height: 12),
            Center(
              child: Column(
                children: [
                  const FriendChatWordmark(markSize: 24, fontSize: 14),
                  const SizedBox(height: 6),
                  Text('Friend Chat 1.0.0 · self-hosted', style: FcText.caption),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 5),
      child: Row(
        children: [
          Text(label, style: FcText.muted.copyWith(fontSize: 12.5)),
          const Spacer(),
          Flexible(
            child: Text(
              value,
              textAlign: TextAlign.right,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 12.5, color: FcColors.text),
            ),
          ),
        ],
      ),
    );
  }
}
