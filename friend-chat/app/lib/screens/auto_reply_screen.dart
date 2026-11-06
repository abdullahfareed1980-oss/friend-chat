import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/business_controller.dart';
import '../theme/friend_chat_theme.dart';
import '../widgets/common.dart';

/// ---------------------------------------------------------------------------
/// Greeting + away messages.
///
/// These run on the device (the server has no plaintext), so the schedule is
/// evaluated against the local clock at the moment a message arrives.
/// ---------------------------------------------------------------------------

class AutoReplyScreen extends StatefulWidget {
  const AutoReplyScreen({super.key});

  @override
  State<AutoReplyScreen> createState() => _AutoReplyScreenState();
}

class _AutoReplyScreenState extends State<AutoReplyScreen> {
  late AutoReplySettings _draft;
  late TextEditingController _greeting;
  late TextEditingController _away;
  bool _dirty = false;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _draft = context.read<BusinessController>().autoReply;
    _greeting = TextEditingController(text: _draft.greetingText)
      ..addListener(() => _markDirty());
    _away = TextEditingController(text: _draft.awayText)..addListener(() => _markDirty());
  }

  void _markDirty() {
    if (!_dirty) setState(() => _dirty = true);
  }

  @override
  void dispose() {
    _greeting.dispose();
    _away.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await context.read<BusinessController>().saveAutoReply(
          _draft.copyWith(greetingText: _greeting.text.trim(), awayText: _away.text.trim()),
        );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _dirty = false;
    });
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Automation saved')));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Greeting & away'),
        actions: [
          TextButton(
            onPressed: _dirty && !_saving ? _save : null,
            child: Text(_saving ? 'Saving…' : 'Save'),
          ),
        ],
      ),
      body: FcScaffold(
        padded: true,
        child: ListView(
          padding: const EdgeInsets.only(top: 12, bottom: FcSpace.xl),
          children: [
            _SwitchCard(
              icon: Icons.waving_hand_rounded,
              title: 'Greeting message',
              subtitle: 'Sent automatically when a conversation restarts after a quiet spell.',
              value: _draft.greetingEnabled,
              onChanged: (value) => setState(() => _draft = _draft.copyWith(greetingEnabled: value)),
            ),
            if (_draft.greetingEnabled)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: _greeting,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Greeting text'),
                ),
              ),
            _SwitchCard(
              icon: Icons.nights_stay_rounded,
              title: 'Away message',
              subtitle: 'Replies while you are outside your working hours.',
              value: _draft.awayEnabled,
              onChanged: (value) => setState(() => _draft = _draft.copyWith(awayEnabled: value)),
            ),
            if (_draft.awayEnabled) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: TextField(
                  controller: _away,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(labelText: 'Away text'),
                ),
              ),
              FcCard(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('AWAY WINDOW', style: FcText.section),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: _HourPicker(
                            label: 'From',
                            value: _draft.awaySchedule.startHour,
                            onChanged: (hour) => setState(() {
                              _draft = _draft.copyWith(
                                awaySchedule: AwaySchedule(startHour: hour, endHour: _draft.awaySchedule.endHour),
                              );
                            }),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: _HourPicker(
                            label: 'Until',
                            value: _draft.awaySchedule.endHour,
                            onChanged: (hour) => setState(() {
                              _draft = _draft.copyWith(
                                awaySchedule: AwaySchedule(startHour: _draft.awaySchedule.startHour, endHour: hour),
                              );
                            }),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Text(
                      _draft.awaySchedule.startHour == _draft.awaySchedule.endHour
                          ? 'Away replies are off: the window is empty.'
                          : 'Away between ${_draft.awaySchedule.label}, every day.',
                      style: FcText.caption,
                    ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 12),
            FcCard(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      const Text('COOLDOWN', style: FcText.section),
                      const Spacer(),
                      Text('${_draft.cooldownHours}h', style: const TextStyle(fontWeight: FontWeight.w700, color: FcColors.mint)),
                    ],
                  ),
                  Slider(
                    value: _draft.cooldownHours.toDouble(),
                    min: 1,
                    max: 24,
                    divisions: 23,
                    activeColor: FcColors.mint,
                    label: '${_draft.cooldownHours}h',
                    onChanged: (value) => setState(() => _draft = _draft.copyWith(cooldownHours: value.round())),
                  ),
                  Text(
                    'Someone never gets the same automatic reply twice inside this window.',
                    style: FcText.caption.copyWith(height: 1.4),
                  ),
                ],
              ),
            ),
            const SizedBox(height: FcSpace.lg),
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
                  const Icon(Icons.lock_rounded, size: 14, color: FcColors.mint),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Automation runs on this device. The server stores your settings '
                      'as metadata but never sees the message that gets sent.',
                      style: FcText.caption.copyWith(height: 1.45),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SwitchCard extends StatelessWidget {
  const _SwitchCard({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: FcCard(
        child: Row(
          children: [
            Icon(icon, size: 20, color: value ? FcColors.mint : FcColors.textFaint),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontSize: 14.5, fontWeight: FontWeight.w600)),
                  const SizedBox(height: 2),
                  Text(subtitle, style: FcText.caption.copyWith(height: 1.4)),
                ],
              ),
            ),
            Switch(value: value, onChanged: onChanged),
          ],
        ),
      ),
    );
  }
}

class _HourPicker extends StatelessWidget {
  const _HourPicker({required this.label, required this.value, required this.onChanged});

  final String label;
  final int value;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<int>(
      initialValue: value,
      decoration: InputDecoration(labelText: label),
      dropdownColor: FcColors.surfaceHigh,
      items: List.generate(
        24,
        (hour) => DropdownMenuItem(
          value: hour,
          child: Text('${hour.toString().padLeft(2, '0')}:00'),
        ),
      ),
      onChanged: (hour) {
        if (hour != null) onChanged(hour);
      },
    );
  }
}
