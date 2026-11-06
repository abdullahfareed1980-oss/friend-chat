import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_session.dart';
import '../state/business_controller.dart';
import '../state/chat_controller.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';
import '../widgets/friend_chat_logo.dart';
import 'business_hub_screen.dart';
import 'chat_screen.dart';
import 'settings_screen.dart';

/// ---------------------------------------------------------------------------
/// Home. One conversation, because Friend Chat is a two-person product.
/// ---------------------------------------------------------------------------

class ChatListScreen extends StatelessWidget {
  const ChatListScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final chat = context.watch<ChatController>();
    final business = context.watch<BusinessController>();
    final peer = session.peer;
    final me = session.user;

    return Scaffold(
      body: FcScaffold(
        padded: false,
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(FcSpace.md, FcSpace.sm, FcSpace.md, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                    child: FcAvatar(
                      name: me?.displayName ?? 'Me',
                      size: 40,
                      accentHex: me?.accentColor ?? '#4F46E5',
                    ),
                  ),
                  const Spacer(),
                  const FriendChatWordmark(markSize: 30, fontSize: 18),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.settings_outlined, size: 21),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(builder: (_) => const SettingsScreen()),
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(FcSpace.md, 4, FcSpace.md, 10),
              child: Row(
                children: [
                  const ConnectionPill(compact: true),
                  const Spacer(),
                  if (chat.syncing)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(strokeWidth: 1.6),
                    ),
                ],
              ),
            ),
            if (chat.lastSyncError != null)
              Container(
                margin: const EdgeInsets.symmetric(horizontal: FcSpace.md),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: FcColors.warning.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(FcRadius.md),
                  border: Border.all(color: FcColors.warning.withValues(alpha: 0.3)),
                ),
                child: Text(
                  chat.lastSyncError!,
                  style: const TextStyle(fontSize: 11.5, color: FcColors.warning, height: 1.4),
                ),
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(FcSpace.md, 8, FcSpace.md, FcSpace.xl),
                children: [
                  if (peer != null) _ConversationTile(peer: peer),
                  if (business.activeLabels.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          for (final label in business.activeLabels)
                            LabelChip(label: label),
                        ],
                      ),
                    ),
                  if (session.user?.isBusiness == true) ...[
                    const SectionHeader(title: 'Business tools'),
                    _BusinessBanner(
                      business: business,
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(builder: (_) => const BusinessHubScreen()),
                      ),
                    ),
                  ],
                  const SizedBox(height: FcSpace.lg),
                  _PrivacyFooter(peer: peer, ready: session.peerReadyToEncrypt),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationTile extends StatelessWidget {
  const _ConversationTile({required this.peer});

  final ChatUser peer;

  @override
  Widget build(BuildContext context) {
    final chat = context.watch<ChatController>();
    final last = chat.lastMessage;

    final preview = last == null
        ? 'Say hello — nothing leaves this server.'
        : last.deleted
            ? 'Message deleted'
            : last.isMedia
                ? '📎 ${last.media?.fileName ?? 'Attachment'}'
                : last.isCatalog
                    ? '🛍 ${last.catalog?.name ?? 'Catalog item'}'
                    : last.text ?? 'Encrypted message';

    return FcCard(
      padding: const EdgeInsets.all(14),
      glow: FcColors.indigo,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => ChatScreen(peer: peer)),
      ),
      child: Row(
        children: [
          FcAvatar(
            name: peer.displayName,
            size: 54,
            accentHex: peer.accentColor,
            isBusiness: peer.isBusiness,
            showOnline: chat.peerOnline,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        peer.businessName ?? peer.displayName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: FcColors.text),
                      ),
                    ),
                    if (peer.isBusiness) ...[
                      const SizedBox(width: 6),
                      const FcBadge(text: 'BUSINESS'),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Row(
                  children: [
                    if (last != null && last.outgoing) ...[
                      Icon(
                        last.effectiveStatus == MessageStatus.read
                            ? Icons.done_all_rounded
                            : last.effectiveStatus == MessageStatus.delivered
                                ? Icons.done_all_rounded
                                : Icons.done_rounded,
                        size: 13,
                        color: last.effectiveStatus == MessageStatus.read ? FcColors.mint : FcColors.textFaint,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        chat.peerTyping ? 'typing…' : preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          color: chat.peerTyping ? FcColors.mint : FcColors.textMuted,
                          fontStyle: chat.peerTyping ? FontStyle.italic : FontStyle.normal,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                last == null ? '' : formatRelative(last.createdAt),
                style: FcText.caption,
              ),
              const SizedBox(height: 6),
              if (chat.unreadCount > 0)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                  decoration: BoxDecoration(
                    color: FcColors.mint,
                    borderRadius: BorderRadius.circular(FcRadius.pill),
                  ),
                  child: Text(
                    '${chat.unreadCount}',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w700, color: Color(0xFF04231A)),
                  ),
                )
              else
                const Icon(Icons.chevron_right_rounded, size: 18, color: FcColors.textFaint),
            ],
          ),
        ],
      ),
    );
  }
}

class _BusinessBanner extends StatelessWidget {
  const _BusinessBanner({required this.business, required this.onTap});

  final BusinessController business;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FcCard(
      onTap: onTap,
      borderColor: FcColors.mint.withValues(alpha: 0.35),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: FcColors.mint.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(Icons.storefront_rounded, size: 20, color: FcColors.mint),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Quick replies, catalog, labels',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: FcColors.text),
                ),
                const SizedBox(height: 2),
                Text(business.autoReplyLine, style: FcText.muted.copyWith(fontSize: 12)),
              ],
            ),
          ),
          const Icon(Icons.arrow_forward_ios_rounded, size: 14, color: FcColors.textFaint),
        ],
      ),
    );
  }
}

class _PrivacyFooter extends StatelessWidget {
  const _PrivacyFooter({required this.peer, required this.ready});

  final ChatUser? peer;
  final bool ready;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: FcColors.surface.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(FcRadius.md),
        border: Border.all(color: FcColors.divider),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            ready ? Icons.verified_user_rounded : Icons.key_off_rounded,
            size: 15,
            color: ready ? FcColors.mint : FcColors.warning,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              ready
                  ? 'End-to-end encrypted with ${peer?.displayName ?? 'your friend'}. Even the server cannot read these messages.'
                  : '${peer?.displayName ?? 'Your friend'} has not opened Friend Chat yet, so their key is unknown. Messages will unlock once they do.',
              style: FcText.caption.copyWith(height: 1.45),
            ),
          ),
        ],
      ),
    );
  }
}
