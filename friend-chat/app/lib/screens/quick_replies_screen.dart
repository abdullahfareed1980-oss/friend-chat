import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/business_controller.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';

/// ---------------------------------------------------------------------------
/// Quick replies: canned answers with a `/shortcut`.
/// ---------------------------------------------------------------------------

class QuickRepliesScreen extends StatelessWidget {
  const QuickRepliesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final business = context.watch<BusinessController>();
    final replies = business.quickReplies;

    return Scaffold(
      appBar: AppBar(title: const Text('Quick replies')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: FcColors.indigoDeep,
        onPressed: () => _edit(context, business.newQuickReply()),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New reply'),
      ),
      body: FcScaffold(
        padded: true,
        child: replies.isEmpty
            ? const EmptyState(
                icon: Icons.bolt_outlined,
                title: 'No quick replies',
                message: 'Save the answers you type most — addresses, opening hours, prices — and send them in one tap.',
              )
            : ListView.separated(
                padding: const EdgeInsets.only(top: 12, bottom: 90),
                itemCount: replies.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final reply = replies[index];
                  return FcCard(
                    onTap: () => _edit(context, reply),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              reply.shortcut,
                              style: FcText.mono.copyWith(color: FcColors.mint, fontSize: 12),
                            ),
                            const Spacer(),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.delete_outline_rounded, size: 18, color: FcColors.textFaint),
                              onPressed: () => business.deleteQuickReply(reply.id),
                            ),
                          ],
                        ),
                        Text(
                          reply.title,
                          style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(reply.body, maxLines: 3, overflow: TextOverflow.ellipsis, style: FcText.muted),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, QuickReply reply) async {
    final business = context.read<BusinessController>();
    final shortcut = TextEditingController(text: reply.shortcut);
    final title = TextEditingController(text: reply.title);
    final body = TextEditingController(text: reply.body);

    final saved = await showDialog<QuickReply>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(reply.body.isEmpty ? 'New quick reply' : 'Edit quick reply'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: shortcut,
                decoration: const InputDecoration(labelText: 'Shortcut', hintText: '/address'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: title,
                decoration: const InputDecoration(labelText: 'Title', hintText: 'Studio address'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: body,
                minLines: 3,
                maxLines: 6,
                decoration: const InputDecoration(labelText: 'Message', hintText: 'Jl. Merdeka 12, Bandung'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(
              reply.copyWith(shortcut: shortcut.text.trim(), title: title.text.trim(), body: body.text.trim()),
            ),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    shortcut.dispose();
    title.dispose();
    body.dispose();

    if (saved != null && saved.body.isNotEmpty) {
      await business.saveQuickReply(saved);
    }
  }
}
