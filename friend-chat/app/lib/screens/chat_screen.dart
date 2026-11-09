import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_session.dart';
import '../state/business_controller.dart';
import '../state/chat_controller.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';
import '../widgets/message_bubble.dart';
import 'business_hub_screen.dart';
import 'labels_screen.dart';

/// ---------------------------------------------------------------------------
/// The conversation.
/// ---------------------------------------------------------------------------

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.peer});

  final ChatUser peer;

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _composer = TextEditingController();
  final ScrollController _scroll = ScrollController();
  Timer? _scrollDebounce;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatController>().markConversationRead();
      _jumpToBottom();
    });
  }

  @override
  void dispose() {
    _scrollDebounce?.cancel();
    _composer.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _jumpToBottom({bool animate = false}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scroll.hasClients) return;
      final target = _scroll.position.maxScrollExtent;
      if (animate) {
        _scroll.animateTo(target, duration: const Duration(milliseconds: 220), curve: Curves.easeOut);
      } else {
        _scroll.jumpTo(target);
      }
    });
  }

  Future<void> _send() async {
    final text = _composer.text;
    if (text.trim().isEmpty) return;
    _composer.clear();
    await context.read<ChatController>().sendText(text);
    _jumpToBottom(animate: true);
  }

  Future<void> _showQuickReplies() async {
    final business = context.read<BusinessController>();
    if (business.quickReplies.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('No quick replies yet.'),
          action: SnackBarAction(
            label: 'Create',
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BusinessHubScreen()),
            ),
          ),
        ),
      );
      return;
    }

    final picked = await showModalBottomSheet<QuickReply>(
      context: context,
      backgroundColor: FcColors.night,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(FcRadius.lg)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  Icon(Icons.bolt_rounded, size: 17, color: FcColors.mint),
                  SizedBox(width: 8),
                  Text('QUICK REPLIES', style: FcText.section),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: business.quickReplies.length,
                itemBuilder: (context, index) {
                  final reply = business.quickReplies[index];
                  return ListTile(
                    onTap: () => Navigator.of(context).pop(reply),
                    title: Text(reply.title, style: const TextStyle(fontSize: 14.5)),
                    subtitle: Text(reply.body, maxLines: 2, overflow: TextOverflow.ellipsis),
                    trailing: Text(reply.shortcut, style: FcText.mono.copyWith(fontSize: 11)),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (picked != null) {
      setState(() => _composer.text = picked.body);
      _send();
    }
  }

  Future<void> _showCatalog() async {
    final business = context.read<BusinessController>();
    final items = [...business.catalog.where((i) => i.active), ...business.peerCatalog];

    if (items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Your catalog is empty. Add an item first.')),
      );
      return;
    }

    final picked = await showModalBottomSheet<CatalogItem>(
      context: context,
      backgroundColor: FcColors.night,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(FcRadius.lg)),
      ),
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 8),
              child: Row(
                children: [
                  Icon(Icons.storefront_rounded, size: 17, color: FcColors.mint),
                  SizedBox(width: 8),
                  Text('SHARE A CATALOG ITEM', style: FcText.section),
                ],
              ),
            ),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: items.length,
                itemBuilder: (context, index) {
                  final item = items[index];
                  return ListTile(
                    onTap: () => Navigator.of(context).pop(item),
                    title: Text(item.name, style: const TextStyle(fontSize: 14.5)),
                    subtitle: item.description == null
                        ? null
                        : Text(item.description!, maxLines: 1, overflow: TextOverflow.ellipsis),
                    trailing: Text(
                      item.priceLabel,
                      style: const TextStyle(fontWeight: FontWeight.w700, color: FcColors.mint),
                    ),
                  );
                },
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );

    if (picked != null && mounted) {
      await context.read<ChatController>().sendCatalogItem(picked);
      _jumpToBottom(animate: true);
    }
  }

  Future<void> _showMessageActions(ChatMessage message) async {
    if (message.deleted || message.status == MessageStatus.sending) return;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: FcColors.night,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(FcRadius.lg)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.outgoing)
              ListTile(
                leading: const Icon(Icons.delete_outline_rounded, color: FcColors.danger),
                title: const Text('Delete for everyone'),
                subtitle: const Text('Leaves a tombstone on both devices'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.read<ChatController>().deleteForEveryone(message);
                },
              ),
            if (message.status == MessageStatus.failed)
              ListTile(
                leading: const Icon(Icons.refresh_rounded, color: FcColors.mint),
                title: const Text('Retry sending'),
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  context.read<ChatController>().retry(message);
                },
              ),
            ListTile(
              leading: const Icon(Icons.info_outline_rounded, color: FcColors.textMuted),
              title: const Text('Message details'),
              subtitle: Text(
                'seq ${message.seq} · ${message.uuid.substring(0, 8)}… · ${formatClock(message.createdAt)}',
                style: FcText.caption,
              ),
              onTap: () => Navigator.of(sheetContext).pop(),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();
    final chat = context.watch<ChatController>();
    final business = context.watch<BusinessController>();
    final messages = chat.messages;

    if (_scroll.hasClients) {
      _scrollDebounce?.cancel();
      _scrollDebounce = Timer(const Duration(milliseconds: 120), () => _jumpToBottom());
    }

    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: Row(
          children: [
            FcAvatar(
              name: widget.peer.displayName,
              size: 38,
              accentHex: widget.peer.accentColor,
              isBusiness: widget.peer.isBusiness,
              showOnline: chat.peerOnline,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    widget.peer.businessName ?? widget.peer.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                  Text(
                    chat.peerTyping
                        ? 'typing…'
                        : chat.peerOnline
                            ? 'online'
                            : 'encrypted · offline',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: chat.peerTyping
                          ? FcColors.mint
                          : chat.peerOnline
                              ? FcColors.mint.withOpacity(0.8)
                              : FcColors.textFaint,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        actions: [
          if (business.activeLabels.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: Center(child: LabelChip(label: business.activeLabels.first)),
            ),
          IconButton(
            tooltip: 'Labels',
            icon: const Icon(Icons.sell_outlined, size: 20),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const LabelsScreen()),
            ),
          ),
          IconButton(
            tooltip: 'Business tools',
            icon: const Icon(Icons.more_vert_rounded, size: 20),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const BusinessHubScreen()),
            ),
          ),
        ],
      ),
      body: FcScaffold(
        padded: true,
        child: Column(
          children: [
            Expanded(
              child: messages.isEmpty
                  ? EmptyState(
                      icon: Icons.forum_outlined,
                      title: 'No messages yet',
                      message: session.peerReadyToEncrypt
                          ? 'This is the beginning of your private line.'
                          : 'Waiting for ${widget.peer.displayName} to publish an encryption key.',
                    )
                  : ListView.builder(
                      controller: _scroll,
                      padding: const EdgeInsets.only(top: 12, bottom: 8),
                      itemCount: messages.length + (chat.peerTyping ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= messages.length) {
                          return TypingIndicator(name: widget.peer.displayName);
                        }
                        final message = messages[index];
                        final previous = index == 0 ? null : messages[index - 1];
                        final needsDivider = previous == null ||
                            previous.createdAt.day != message.createdAt.day ||
                            previous.createdAt.month != message.createdAt.month;

                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (needsDivider) DateDivider(date: message.createdAt),
                            MessageBubble(
                              message: message,
                              onRetry: () => context.read<ChatController>().retry(message),
                              onLongPress: () => _showMessageActions(message),
                            ),
                          ],
                        );
                      },
                    ),
            ),
            _Composer(
              controller: _composer,
              onSend: _send,
              onChanged: (_) => context.read<ChatController>().notifyTypingTimer(),
              onQuickReplies: _showQuickReplies,
              onCatalog: _showCatalog,
              onAttach: () async {
                await context.read<ChatController>().pickAndSendAttachment();
                _jumpToBottom(animate: true);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.onSend,
    required this.onChanged,
    required this.onQuickReplies,
    required this.onCatalog,
    required this.onAttach,
  });

  final TextEditingController controller;
  final VoidCallback onSend;
  final ValueChanged<String> onChanged;
  final VoidCallback onQuickReplies;
  final VoidCallback onCatalog;
  final Future<void> Function() onAttach;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: FcColors.divider)),
      ),
      child: Column(
        children: [
          Row(
            children: [
              _CircleAction(icon: Icons.bolt_rounded, tooltip: 'Quick replies', onTap: onQuickReplies),
              _CircleAction(icon: Icons.storefront_outlined, tooltip: 'Share catalog item', onTap: onCatalog),
              _CircleAction(icon: Icons.attach_file_rounded, tooltip: 'Attach', onTap: onAttach),
            ],
          ),
          const SizedBox(height: 6),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
                  onChanged: onChanged,
                  minLines: 1,
                  maxLines: 5,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Message',
                    contentPadding: EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              GestureDetector(
                onTap: onSend,
                child: Container(
                  width: 50,
                  height: 50,
                  decoration: BoxDecoration(
                    gradient: FcColors.primaryGradient,
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(color: FcColors.indigo.withOpacity(0.35), blurRadius: 16, offset: const Offset(0, 6)),
                    ],
                  ),
                  child: const Icon(Icons.arrow_upward_rounded, color: Colors.white, size: 21),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(30),
        child: Container(
          width: 38,
          height: 38,
          margin: const EdgeInsets.only(right: 8),
          decoration: BoxDecoration(
            color: FcColors.surfaceHigh,
            shape: BoxShape.circle,
            border: Border.all(color: FcColors.divider),
          ),
          child: Icon(icon, size: 18, color: FcColors.textMuted),
        ),
      ),
    );
  }
}