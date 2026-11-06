import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/app_session.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';
import '../widgets/friend_chat_logo.dart';
import 'phone_screen.dart';

/// ---------------------------------------------------------------------------
/// Step 0 of onboarding: where is your server?
///
/// Several addresses can be saved at once - the LAN IP for when you are home,
/// the public hostname for mobile data. The app races them at runtime, so the
/// user never has to remember which one they are on.
/// ---------------------------------------------------------------------------

class ServerSetupScreen extends StatefulWidget {
  const ServerSetupScreen({super.key});

  @override
  State<ServerSetupScreen> createState() => _ServerSetupScreenState();
}

class _ServerSetupScreenState extends State<ServerSetupScreen> {
  final List<TextEditingController> _controllers = [TextEditingController()];
  final Map<int, String> _status = {};
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _test(int index) async {
    final session = context.read<AppSession>();
    final url = _controllers[index].text.trim();
    if (url.isEmpty) return;

    setState(() {
      _status[index] = 'testing';
      _error = null;
    });

    final health = await session.testServer(url);
    if (!mounted) return;
    setState(() {
      _status[index] = health == null
          ? 'unreachable'
          : 'ok:${health['service'] ?? 'Friend Chat Server'} · ${health['users'] ?? 0}/${health['maxUsers'] ?? 2} accounts';
    });
  }

  Future<void> _saveAndContinue() async {
    final session = context.read<AppSession>();
    final urls = _controllers.map((c) => c.text.trim()).where((u) => u.isNotEmpty).toList();

    if (urls.isEmpty) {
      setState(() => _error = 'Add at least one server address.');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    await session.setEndpoints(urls);
    final reachable = await session.testServer(urls.first);

    if (!mounted) return;
    if (reachable == null) {
      setState(() {
        _busy = false;
        _error = 'Could not reach ${urls.first}. Is Friend Chat Server running and on the same network?';
      });
      return;
    }

    setState(() => _busy = false);
    Navigator.of(context).pushReplacement(MaterialPageRoute(builder: (_) => const PhoneScreen()));
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
      ),
      body: FcScaffold(
        padded: true,
        child: ListView(
          padding: const EdgeInsets.only(top: FcSpace.md, bottom: FcSpace.xl),
          children: [
            const Text('Connect to your\nFriend Chat Server', style: FcText.display),
            const SizedBox(height: FcSpace.sm),
            Text(
              'Add every address that points at the same server. The app will pick '
              'the fastest one and switch automatically when you leave the house.',
              style: FcText.muted.copyWith(height: 1.5),
            ),
            const SizedBox(height: FcSpace.lg),
            ..._controllers.asMap().entries.map((entry) {
              final index = entry.key;
              final status = _status[index];
              return Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: entry.value,
                            autocorrect: false,
                            keyboardType: TextInputType.url,
                            decoration: InputDecoration(
                              hintText: index == 0 ? 'http://192.168.1.40:8787' : 'https://chat.example.com',
                              prefixIcon: const Icon(Icons.dns_rounded, size: 19),
                              suffixIcon: IconButton(
                                icon: const Icon(Icons.bolt_rounded, size: 19),
                                tooltip: 'Test this address',
                                onPressed: () => _test(index),
                              ),
                            ),
                          ),
                        ),
                        if (_controllers.length > 1)
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline_rounded, color: FcColors.textFaint),
                            onPressed: () => setState(() {
                              _controllers.removeAt(index).dispose();
                              _status.clear();
                            }),
                          ),
                      ],
                    ),
                    if (status != null)
                      Padding(
                        padding: const EdgeInsets.only(left: 6, top: 6),
                        child: Text(
                          switch (status) {
                            'testing' => 'Testing…',
                            'unreachable' => 'No answer from this address',
                            _ => status.replaceFirst('ok:', 'Reachable · '),
                          },
                          style: TextStyle(
                            fontSize: 11.5,
                            color: status.startsWith('ok:')
                                ? FcColors.mint
                                : status == 'testing'
                                    ? FcColors.violetSoft
                                    : FcColors.danger,
                          ),
                        ),
                      ),
                  ],
                ),
              );
            }),
            TextButton.icon(
              onPressed: () => setState(() => _controllers.add(TextEditingController())),
              icon: const Icon(Icons.add_rounded, size: 18),
              label: const Text('Add another address'),
            ),
            const SizedBox(height: FcSpace.md),
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: FcColors.surface,
                borderRadius: BorderRadius.circular(FcRadius.md),
                border: Border.all(color: FcColors.divider),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.wifi_rounded, size: 16, color: FcColors.mint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'At home use the LAN address (fast, no internet needed). '
                      'On mobile data use your Tailscale address or your HTTPS domain.',
                      style: FcText.muted.copyWith(fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: FcSpace.md),
              Text(_error!, style: const TextStyle(color: FcColors.danger, fontSize: 12.5)),
            ],
            const SizedBox(height: FcSpace.lg),
            GradientButton(
              label: 'Continue',
              icon: Icons.arrow_forward_rounded,
              loading: _busy,
              onPressed: _saveAndContinue,
            ),
          ],
        ),
      ),
    );
  }
}
