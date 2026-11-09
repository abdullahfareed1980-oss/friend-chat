import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../state/business_controller.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';
import 'auto_reply_screen.dart';
import 'catalog_screen.dart';
import 'labels_screen.dart';
import 'quick_replies_screen.dart';

/// ---------------------------------------------------------------------------
/// The WhatsApp Business corner of Friend Chat.
/// ---------------------------------------------------------------------------

class BusinessHubScreen extends StatelessWidget {
  const BusinessHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final business = context.watch<BusinessController>();

    return Scaffold(
      appBar: AppBar(
        title: const Text('Business tools'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, size: 20),
            onPressed: () => context.read<BusinessController>().load(),
          ),
        ],
      ),
      body: FcScaffold(
        padded: true,
        child: ListView(
          padding: const EdgeInsets.only(top: 8, bottom: FcSpace.xl),
          children: [
            FcCard(
              borderColor: FcColors.mint.withOpacity(0.3),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Icon(Icons.auto_awesome_rounded, size: 16, color: FcColors.mint),
                      const SizedBox(width: 8),
                      const Text('AUTOMATION', style: FcText.section),
                      const Spacer(),
                      if (business.loading)
                        const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  Text(business.autoReplyLine, style: const TextStyle(fontSize: 14, color: FcColors.text)),
                  const SizedBox(height: 4),
                  Text(
                    'Auto replies are composed on this device and sent as normal '
                    'encrypted messages, so the server never sees them.',
                    style: FcText.caption.copyWith(height: 1.4),
                  ),
                ],
              ),
            ),
            if (business.error != null)
              Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Text(business.error!, style: const TextStyle(color: FcColors.warning, fontSize: 12)),
              ),
            const SectionHeader(title: 'Tools'),
            _ToolCard(
              icon: Icons.bolt_rounded,
              title: 'Quick replies',
              subtitle: '${business.quickReplies.length} saved · insert with one tap',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const QuickRepliesScreen())),
            ),
            _ToolCard(
              icon: Icons.nights_stay_rounded,
              title: 'Greeting & away messages',
              subtitle: business.autoReplyLine,
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const AutoReplyScreen())),
            ),
            _ToolCard(
              icon: Icons.storefront_rounded,
              title: 'Catalog',
              subtitle: '${business.catalog.length} items · share inside a chat',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const CatalogScreen())),
            ),
            _ToolCard(
              icon: Icons.sell_rounded,
              title: 'Labels',
              subtitle: '${business.labels.length} tags · ${business.activeLabels.length} on this chat',
              onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const LabelsScreen())),
            ),
            if (business.peerCatalog.isNotEmpty) ...[
              const SectionHeader(title: 'Their catalog'),
              FcCard(
                child: Column(
                  children: [
                    for (final item in business.peerCatalog.take(5))
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 7),
                        child: Row(
                          children: [
                            const Icon(Icons.local_offer_outlined, size: 14, color: FcColors.violetSoft),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(item.name, style: const TextStyle(fontSize: 13.5)),
                            ),
                            Text(item.priceLabel, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: FcColors.mint)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: FcSpace.lg),
            Center(
              child: Text(
                'These documents sync through your server in plain text.',
                style: FcText.caption,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ToolCard extends StatelessWidget {
  const _ToolCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: FcCard(
        onTap: onTap,
        child: Row(
          children: [
            Container(
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                color: FcColors.indigo.withOpacity(0.14),
                borderRadius: BorderRadius.circular(13),
              ),
              child: Icon(icon, size: 19, color: FcColors.violetSoft),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle, maxLines: 1, overflow: TextOverflow.ellipsis, style: FcText.muted.copyWith(fontSize: 12)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded, size: 18, color: FcColors.textFaint),
          ],
        ),
      ),
    );
  }
}