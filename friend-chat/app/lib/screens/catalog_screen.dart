import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/business_controller.dart';
import '../state/chat_controller.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';

/// ---------------------------------------------------------------------------
/// A small product/service catalog, WhatsApp Business style: name, price,
/// description, and one tap to drop it into the conversation as an encrypted
/// message.
/// ---------------------------------------------------------------------------

class CatalogScreen extends StatelessWidget {
  const CatalogScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final business = context.watch<BusinessController>();
    final items = business.catalog;

    return Scaffold(
      appBar: AppBar(title: const Text('Catalog')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: FcColors.indigoDeep,
        onPressed: () => _edit(context, business.newCatalogItem()),
        icon: const Icon(Icons.add_rounded),
        label: const Text('Add item'),
      ),
      body: FcScaffold(
        padded: true,
        child: items.isEmpty
            ? const EmptyState(
                icon: Icons.storefront_outlined,
                title: 'Your catalog is empty',
                message: 'Add a product or service and share it in a chat as a tappable card.',
              )
            : ListView.separated(
                padding: const EdgeInsets.only(top: 12, bottom: 90),
                itemCount: items.length,
                separatorBuilder: (_, __) => const SizedBox(height: 10),
                itemBuilder: (context, index) {
                  final item = items[index];
                  return FcCard(
                    onTap: () => _edit(context, item),
                    child: Row(
                      children: [
                        Container(
                          width: 46,
                          height: 46,
                          decoration: BoxDecoration(
                            color: FcColors.mint.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(13),
                            border: Border.all(color: FcColors.mint.withValues(alpha: 0.22)),
                          ),
                          child: const Icon(Icons.local_mall_outlined, size: 20, color: FcColors.mint),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(item.name, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                              if (item.description != null && item.description!.isNotEmpty) ...[
                                const SizedBox(height: 2),
                                Text(item.description!, maxLines: 1, overflow: TextOverflow.ellipsis, style: FcText.caption),
                              ],
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            Text(item.priceLabel, style: const TextStyle(fontWeight: FontWeight.w700, color: FcColors.mint)),
                            const SizedBox(height: 4),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              tooltip: 'Share in chat',
                              icon: const Icon(Icons.send_rounded, size: 16, color: FcColors.violetSoft),
                              onPressed: () async {
                                await context.read<ChatController>().sendCatalogItem(item);
                                if (context.mounted) {
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    SnackBar(content: Text('Shared ${item.name}')),
                                  );
                                }
                              },
                            ),
                          ],
                        ),
                      ],
                    ),
                  );
                },
              ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, CatalogItem item) async {
    final business = context.read<BusinessController>();
    final name = TextEditingController(text: item.name);
    final description = TextEditingController(text: item.description ?? '');
    final price = TextEditingController(text: (item.priceCents / 100).toStringAsFixed(2));
    var currency = item.currency;

    final saved = await showDialog<CatalogItem>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(item.name.isEmpty ? 'New catalog item' : 'Edit item'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: name,
                  decoration: const InputDecoration(labelText: 'Name', hintText: 'Hand-thrown mug'),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: description,
                  minLines: 2,
                  maxLines: 4,
                  decoration: const InputDecoration(labelText: 'Description'),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: price,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        decoration: const InputDecoration(labelText: 'Price'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    DropdownButton<String>(
                      value: currency,
                      dropdownColor: FcColors.surfaceHigh,
                      items: const [
                        DropdownMenuItem(value: 'EUR', child: Text('EUR')),
                        DropdownMenuItem(value: 'USD', child: Text('USD')),
                        DropdownMenuItem(value: 'GBP', child: Text('GBP')),
                        DropdownMenuItem(value: 'IDR', child: Text('IDR')),
                        DropdownMenuItem(value: 'INR', child: Text('INR')),
                      ],
                      onChanged: (value) {
                        if (value != null) setDialogState(() => currency = value);
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
          actions: [
            if (item.name.isNotEmpty)
              TextButton(
                onPressed: () {
                  business.deleteCatalogItem(item.id);
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Delete', style: TextStyle(color: FcColors.danger)),
              ),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () {
                final cents = ((double.tryParse(price.text.replaceAll(',', '.')) ?? 0) * 100).round();
                Navigator.of(dialogContext).pop(
                  CatalogItem(
                    id: item.id,
                    name: name.text.trim(),
                    priceCents: cents,
                    currency: currency,
                    description: description.text.trim(),
                    imageMediaId: item.imageMediaId,
                    active: item.active,
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    name.dispose();
    description.dispose();
    price.dispose();

    if (saved != null && saved.name.isNotEmpty) {
      await business.saveCatalogItem(saved);
    }
  }
}
