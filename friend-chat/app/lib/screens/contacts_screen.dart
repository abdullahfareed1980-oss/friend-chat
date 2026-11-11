import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_session.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';
import 'chat_screen.dart';

/// ---------------------------------------------------------------------------
/// WhatsApp-style Contact & User Discovery.
///
/// Automatically syncs all registered users on the server database so any user
/// can start a direct 1-on-1 encrypted chat with zero terminal intervention.
/// ---------------------------------------------------------------------------

class ContactsScreen extends StatefulWidget {
  const ContactsScreen({super.key});

  @override
  State<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends State<ContactsScreen> {
  final TextEditingController _search = TextEditingController();
  bool _searching = false;
  bool _loading = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadContacts();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _loadContacts() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final session = context.read<AppSession>();
      await session.refreshContacts();
    } catch (err) {
      if (mounted) setState(() => _error = 'Could not sync contacts.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _startChatWith(ChatUser contact) async {
    final session = context.read<AppSession>();
    try {
      await session.openConversationWith(contact);
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen(peer: contact),
        ),
      );
    } catch (err) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Could not open conversation: $err'),
          backgroundColor: FcColors.danger,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final query = _search.text.trim().toLowerCase();

    final filtered = session.contacts.where((c) {
      if (query.isEmpty) return true;
      final name = c.displayName.toLowerCase();
      final phone = (c.phone ?? '').toLowerCase();
      final email = (c.email ?? '').toLowerCase();
      return name.contains(query) || phone.contains(query) || email.contains(query);
    }).toList();

    return Scaffold(
      appBar: AppBar(
        title: _searching
            ? TextField(
                controller: _search,
                autofocus: true,
                style: const TextStyle(fontSize: 16),
                decoration: const InputDecoration(
                  hintText: 'Search by name, phone, or email…',
                  border: InputBorder.none,
                ),
                onChanged: (_) => setState(() {}),
              )
            : Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Select contact', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
                  Text(
                    '${session.contacts.length} registered contacts on server',
                    style: const TextStyle(fontSize: 12, color: FcColors.textMuted),
                  ),
                ],
              ),
        actions: [
          IconButton(
            icon: Icon(_searching ? Icons.close_rounded : Icons.search_rounded),
            onPressed: () {
              setState(() {
                if (_searching) {
                  _search.clear();
                  _searching = false;
                } else {
                  _searching = true;
                }
              });
            },
          ),
          IconButton(
            icon: const Icon(Icons.refresh_rounded),
            onPressed: _loadContacts,
          ),
        ],
      ),
      body: FcScaffold(
        padded: false,
        child: RefreshIndicator(
          onRefresh: _loadContacts,
          color: FcColors.mint,
          child: _loading && session.contacts.isEmpty
              ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
              : filtered.isEmpty
                  ? _EmptyContactsView(
                      hasQuery: query.isNotEmpty,
                      onRefresh: _loadContacts,
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const Divider(
                        height: 1,
                        indent: 72,
                        endIndent: 16,
                        color: FcColors.divider,
                      ),
                      itemBuilder: (context, index) {
                        final contact = filtered[index];
                        return _ContactTile(
                          contact: contact,
                          onTap: () => _startChatWith(contact),
                        );
                      },
                    ),
        ),
      ),
    );
  }
}

class _ContactTile extends StatelessWidget {
  const _ContactTile({required this.contact, required this.onTap});

  final ChatUser contact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      onTap: onTap,
      leading: FcAvatar(
        name: contact.displayName,
        size: 46,
        accentHex: contact.accentColor,
        isBusiness: contact.isBusiness,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              contact.displayName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 15.5, fontWeight: FontWeight.w600, color: FcColors.text),
            ),
          ),
          if (contact.isBusiness) ...[
            const SizedBox(width: 6),
            const FcBadge(text: 'BUSINESS'),
          ],
        ],
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 2),
          Text(
            contact.phone ?? contact.email ?? 'Friend Chat user',
            style: const TextStyle(fontSize: 13, color: FcColors.textMuted),
          ),
          if (contact.email != null && contact.phone != null)
            Text(
              contact.email!,
              style: const TextStyle(fontSize: 11.5, color: FcColors.textFaint),
            ),
        ],
      ),
      trailing: const Icon(Icons.chat_bubble_outline_rounded, size: 20, color: FcColors.mint),
    );
  }
}

class _EmptyContactsView extends StatelessWidget {
  const _EmptyContactsView({required this.hasQuery, required this.onRefresh});

  final bool hasQuery;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        const SizedBox(height: 60),
        Center(
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: FcColors.surfaceHigh,
              shape: BoxShape.circle,
              border: Border.all(color: FcColors.divider),
            ),
            child: const Icon(Icons.people_outline_rounded, size: 36, color: FcColors.mint),
          ),
        ),
        const SizedBox(height: 20),
        Text(
          hasQuery ? 'No contacts found' : 'No other contacts yet',
          textAlign: TextAlign.center,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
        const SizedBox(height: 8),
        Text(
          hasQuery
              ? 'Try searching with a different name, phone number, or email.'
              : 'Share your server link with friends! When they open the app and register with their phone and Gmail, they will appear here automatically for direct chatting.',
          textAlign: TextAlign.center,
          style: FcText.muted.copyWith(fontSize: 13.5, height: 1.5),
        ),
        const SizedBox(height: 24),
        Center(
          child: OutlinedButton.icon(
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: const Text('Check again'),
            onPressed: onRefresh,
          ),
        ),
      ],
    );
  }
}
