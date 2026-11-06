import 'package:flutter/material.dart';

import '../models/models.dart';
import '../theme/friend_chat_theme.dart';

/// ---------------------------------------------------------------------------
/// Message rendering: bubbles, the three-tick delivery states, attachments and
/// catalog shares.
/// ---------------------------------------------------------------------------

class MessageBubble extends StatelessWidget {
  const MessageBubble({
    super.key,
    required this.message,
    this.onRetry,
    this.onLongPress,
    this.showTail = true,
  });

  final ChatMessage message;
  final VoidCallback? onRetry;
  final VoidCallback? onLongPress;
  final bool showTail;

  @override
  Widget build(BuildContext context) {
    final outgoing = message.outgoing;

    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
        child: GestureDetector(
          onLongPress: onLongPress,
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: MediaQuery.sizeOf(context).width * 0.78),
            child: Container(
              decoration: BoxDecoration(
                gradient: outgoing ? FcColors.outgoingGradient : null,
                color: outgoing ? null : FcColors.bubbleIn,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(FcRadius.lg),
                  topRight: const Radius.circular(FcRadius.lg),
                  bottomLeft: Radius.circular(outgoing || !showTail ? FcRadius.lg : 6),
                  bottomRight: Radius.circular(!outgoing || !showTail ? FcRadius.lg : 6),
                ),
                border: outgoing ? null : Border.all(color: FcColors.bubbleInBorder),
                boxShadow: outgoing
                    ? [
                        BoxShadow(
                          color: FcColors.indigo.withValues(alpha: 0.22),
                          blurRadius: 16,
                          offset: const Offset(0, 5),
                        ),
                      ]
                    : null,
              ),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 10, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (message.deleted)
                      Text(
                        'This message was deleted',
                        style: TextStyle(
                          fontSize: 14,
                          fontStyle: FontStyle.italic,
                          color: Colors.white.withValues(alpha: 0.65),
                        ),
                      )
                    else ...[
                      if (message.isCatalog && message.catalog != null)
                        _CatalogCard(snapshot: message.catalog!, outgoing: outgoing),
                      if (message.isMedia && message.media != null)
                        _AttachmentTile(media: message.media!, outgoing: outgoing),
                      if (message.text != null && message.text!.isNotEmpty)
                        Padding(
                          padding: EdgeInsets.only(top: message.kind == MessageKind.text ? 0 : 8),
                          child: Text(
                            message.text!,
                            style: TextStyle(
                              fontSize: 15,
                              height: 1.35,
                              color: outgoing ? Colors.white : FcColors.text,
                            ),
                          ),
                        ),
                    ],
                    const SizedBox(height: 4),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (message.kind != MessageKind.text) ...[
                          Icon(
                            message.kind == MessageKind.catalog
                                ? Icons.storefront_rounded
                                : Icons.attach_file_rounded,
                            size: 11,
                            color: Colors.white.withValues(alpha: 0.55),
                          ),
                          const SizedBox(width: 4),
                        ],
                        Text(
                          formatClock(message.createdAt),
                          style: TextStyle(
                            fontSize: 10.5,
                            color: outgoing ? Colors.white.withValues(alpha: 0.7) : FcColors.textFaint,
                          ),
                        ),
                        if (outgoing) ...[
                          const SizedBox(width: 5),
                          StatusTicks(status: message.effectiveStatus),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Sent = one tick, delivered = two ticks, read = two mint ticks.
class StatusTicks extends StatelessWidget {
  const StatusTicks({super.key, required this.status, this.size = 15});

  final MessageStatus status;
  final double size;

  @override
  Widget build(BuildContext context) {
    return switch (status) {
      MessageStatus.sending => SizedBox(
          width: size,
          height: size,
          child: const Padding(
            padding: EdgeInsets.all(3),
            child: CircularProgressIndicator(strokeWidth: 1.4, color: Colors.white70),
          ),
        ),
      MessageStatus.failed => Icon(Icons.error_outline_rounded, size: size, color: FcColors.danger),
      MessageStatus.sent => _Ticks(count: 1, size: size, color: Colors.white.withValues(alpha: 0.75)),
      MessageStatus.delivered => _Ticks(count: 2, size: size, color: Colors.white.withValues(alpha: 0.85)),
      MessageStatus.read => _Ticks(count: 2, size: size, color: FcColors.mintSoft),
    };
  }
}

class _Ticks extends StatelessWidget {
  const _Ticks({required this.count, required this.size, required this.color});

  final int count;
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => SizedBox(
        width: size,
        height: size,
        child: CustomPaint(painter: _TickPainter(count: count, color: color)),
      );
}

class _TickPainter extends CustomPainter {
  const _TickPainter({required this.count, required this.color});

  final int count;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = size.width * 0.10
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;

    void tick(double dx) {
      final path = Path()
        ..moveTo(size.width * (0.12 + dx), size.height * 0.55)
        ..lineTo(size.width * (0.38 + dx), size.height * 0.78)
        ..lineTo(size.width * (0.86 + dx), size.height * 0.26);
      canvas.drawPath(path, paint);
    }

    if (count == 1) {
      tick(0);
    } else {
      tick(-size.width * 0.16);
      tick(size.width * 0.16);
    }
  }

  @override
  bool shouldRepaint(covariant _TickPainter oldDelegate) =>
      oldDelegate.count != count || oldDelegate.color != color;
}

class _AttachmentTile extends StatelessWidget {
  const _AttachmentTile({required this.media, required this.outgoing});

  final MediaAttachment media;
  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    final icon = media.isImage
        ? Icons.image_rounded
        : media.isVideo
            ? Icons.videocam_rounded
            : media.isAudio
                ? Icons.graphic_eq_rounded
                : Icons.insert_drive_file_rounded;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: outgoing ? 0.18 : 0.25),
        borderRadius: BorderRadius.circular(FcRadius.sm),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: FcColors.mint.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: FcColors.mintSoft),
          ),
          const SizedBox(width: 10),
          Flexible(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  media.fileName ?? (media.isImage ? 'Photo' : 'Attachment'),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                const SizedBox(height: 2),
                Text(
                  '${formatBytes(media.sizeBytes)} · encrypted',
                  style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.6)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CatalogCard extends StatelessWidget {
  const _CatalogCard({required this.snapshot, required this.outgoing});

  final CatalogSnapshot snapshot;
  final bool outgoing;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minWidth: 210),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: outgoing ? 0.20 : 0.25),
        borderRadius: BorderRadius.circular(FcRadius.sm),
        border: Border.all(color: FcColors.mint.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              const Icon(Icons.storefront_rounded, size: 13, color: FcColors.mintSoft),
              const SizedBox(width: 6),
              Text(
                'CATALOG ITEM',
                style: TextStyle(
                  fontSize: 9.5,
                  letterSpacing: 0.8,
                  fontWeight: FontWeight.w700,
                  color: FcColors.mintSoft.withValues(alpha: 0.9),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            snapshot.name,
            style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
          ),
          if (snapshot.description != null && snapshot.description!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              snapshot.description!,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, height: 1.3, color: Colors.white.withValues(alpha: 0.72)),
            ),
          ],
          const SizedBox(height: 8),
          Text(
            snapshot.priceLabel,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: FcColors.mint),
          ),
        ],
      ),
    );
  }
}

class DateDivider extends StatelessWidget {
  const DateDivider({super.key, required this.date});

  final DateTime date;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final label = switch (today.difference(day).inDays) {
      0 => 'Today',
      1 => 'Yesterday',
      _ => '${date.day}/${date.month}/${date.year}',
    };

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: FcSpace.md),
      child: Row(
        children: [
          const Expanded(child: Divider()),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Text(
              label.toUpperCase(),
              style: const TextStyle(fontSize: 10, letterSpacing: 1, color: FcColors.textFaint, fontWeight: FontWeight.w600),
            ),
          ),
          const Expanded(child: Divider()),
        ],
      ),
    );
  }
}

/// "Maya is typing…" rendered as three pulsing dots.
class TypingIndicator extends StatefulWidget {
  const TypingIndicator({super.key, required this.name});

  final String name;

  @override
  State<TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<TypingIndicator> with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: FcColors.bubbleIn,
          borderRadius: BorderRadius.circular(FcRadius.lg),
          border: Border.all(color: FcColors.bubbleInBorder),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return Row(
                  children: List.generate(3, (index) {
                    final phase = ((_controller.value + index * 0.2) % 1.0);
                    final lift = (phase < 0.5 ? phase : 1 - phase) * 4;
                    return Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 2),
                      child: Transform.translate(
                        offset: Offset(0, -lift),
                        child: Container(
                          width: 6,
                          height: 6,
                          decoration: BoxDecoration(
                            color: FcColors.mint.withValues(alpha: 0.85),
                            shape: BoxShape.circle,
                          ),
                        ),
                      ),
                    );
                  }),
                );
              },
            ),
            const SizedBox(width: 8),
            Text(
              '${widget.name} is typing',
              style: const TextStyle(fontSize: 11.5, color: FcColors.textMuted),
            ),
          ],
        ),
      ),
    );
  }
}
