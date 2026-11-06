import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/business_controller.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';

/// ---------------------------------------------------------------------------
/// Labels: the coloured tags you attach to a chat ("order", "paid", "vip").
/// ---------------------------------------------------------------------------

class LabelsScreen extends StatelessWidget {
  const LabelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final business = context.watch<BusinessController>();

    return Scaffold(
      appBar: AppBar(title: const Text('Labels')),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: FcColors.indigoDeep,
        onPressed: () => _edit(context, business.newLabel()),
        icon: const Icon(Icons.add_rounded),
        label: const Text('New label'),
      ),
      body: FcScaffold(
        padded: true,
        child: business.labels.isEmpty
            ? const EmptyState(
                icon: Icons.sell_outlined,
                title: 'No labels yet',
                message: 'Create labels to keep the chat organised: orders, payments, follow-ups.',
              )
            : ListView(
                padding: const EdgeInsets.only(top: 12, bottom: 90),
                children: [
                  Text(
                    'Tap to attach or detach a label from this chat.',
                    style: FcText.caption,
                  ),
                  const SizedBox(height: 12),
                  for (final label in business.labels)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: FcCard(
                        borderColor: business.conversationLabels.contains(label.id)
                            ? Color(parseHexColor(label.colorHex)).withValues(alpha: 0.6)
                            : null,
                        onTap: () => business.toggleLabel(label.id),
                        child: Row(
                          children: [
                            Container(
                              width: 12,
                              height: 12,
                              decoration: BoxDecoration(
                                color: Color(parseHexColor(label.colorHex)),
                                borderRadius: BorderRadius.circular(4),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                label.name,
                                style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600),
                              ),
                            ),
                            if (business.conversationLabels.contains(label.id))
                              const Icon(Icons.check_circle_rounded, size: 18, color: FcColors.mint),
                            const SizedBox(width: 6),
                            IconButton(
                              visualDensity: VisualDensity.compact,
                              icon: const Icon(Icons.edit_outlined, size: 17, color: FcColors.textFaint),
                              onPressed: () => _edit(context, label),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _edit(BuildContext context, LabelTag label) async {
    final business = context.read<BusinessController>();
    final name = TextEditingController(text: label.name);
    var color = label.colorHex;

    final saved = await showDialog<LabelTag>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          title: Text(label.name.isEmpty ? 'New label' : 'Edit label'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Label name', hintText: 'Order'),
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: [
                  for (final preset in BusinessController.presetLabelColors)
                    GestureDetector(
                      onTap: () => setDialogState(() => color = preset),
                      child: Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Color(parseHexColor(preset)),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: color == preset ? Colors.white : Colors.transparent,
                            width: 2,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          ),
          actions: [
            if (label.name.isNotEmpty)
              TextButton(
                onPressed: () {
                  business.deleteLabel(label.id);
                  Navigator.of(dialogContext).pop();
                },
                child: const Text('Delete', style: TextStyle(color: FcColors.danger)),
              ),
            TextButton(onPressed: () => Navigator.of(dialogContext).pop(), child: const Text('Cancel')),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(
                LabelTag(id: label.id, name: name.text.trim(), colorHex: color),
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );

    name.dispose();
    if (saved != null && saved.name.isNotEmpty) await business.saveLabel(saved);
  }
}
