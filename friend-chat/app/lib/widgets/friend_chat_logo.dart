import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/friend_chat_theme.dart';

/// ---------------------------------------------------------------------------
/// The Friend Chat mark.
///
/// Two overlapping speech bubbles - the conversation - sitting on a shield
/// outline with three connected nodes - the private, end-to-end encrypted
/// channel. Drawn with a CustomPainter so it stays crisp at 24px in the app bar
/// and at 1024px on a store listing, with no asset loading delay.
/// ---------------------------------------------------------------------------

class FriendChatLogo extends StatelessWidget {
  const FriendChatLogo({
    super.key,
    this.size = 96,
    this.showPlate = true,
    this.glow = true,
  });

  final double size;
  final bool showPlate;
  final bool glow;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: DecoratedBox(
        decoration: showPlate
            ? BoxDecoration(
                borderRadius: BorderRadius.circular(size * 0.28),
                boxShadow: glow
                    ? [
                        BoxShadow(
                          color: FcColors.indigo.withOpacity(0.35),
                          blurRadius: size * 0.35,
                          spreadRadius: size * 0.02,
                        ),
                      ]
                    : null,
              )
            : const BoxDecoration(),
        child: CustomPaint(painter: _LogoPainter(showPlate: showPlate)),
      ),
    );
  }
}

class _LogoPainter extends CustomPainter {
  const _LogoPainter({required this.showPlate});

  final bool showPlate;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / 100;
    canvas.save();
    canvas.scale(scale.clamp(0.0001, double.infinity), scale.clamp(0.0001, double.infinity));

    if (showPlate) {
      final plate = RRect.fromRectAndRadius(const Rect.fromLTWH(0, 0, 100, 100), const Radius.circular(28));
      canvas.drawRRect(
        plate,
        Paint()
          ..shader = const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF4F46E5), Color(0xFF7C3AED), Color(0xFF1E1B4B)],
            stops: [0.0, 0.55, 1.0],
          ).createShader(const Rect.fromLTWH(0, 0, 100, 100)),
      );
      canvas.drawRRect(
        plate,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = Colors.white.withOpacity(0.12),
      );
    }

    // --- shield outline -----------------------------------------------------
    final shield = Path()
      ..moveTo(50, 12)
      ..quadraticBezierTo(76, 20, 82, 26)
      ..lineTo(82, 48)
      ..cubicTo(82, 68, 68, 82, 50, 90)
      ..cubicTo(32, 82, 18, 68, 18, 48)
      ..lineTo(18, 26)
      ..quadraticBezierTo(24, 20, 50, 12)
      ..close();

    canvas.drawPath(
      shield,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.4
        ..color = FcColors.mint.withOpacity(0.5),
    );
    canvas.drawPath(
      shield,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, -0.4),
          radius: 0.9,
          colors: [
            FcColors.mint.withOpacity(0.16),
            Colors.transparent,
          ],
        ).createShader(const Rect.fromLTWH(14, 10, 72, 82)),
    );

    // --- back bubble --------------------------------------------------------
    final back = RRect.fromRectAndRadius(
      const Rect.fromLTWH(24, 30, 42, 30),
      const Radius.circular(11),
    );
    canvas.drawRRect(back, Paint()..color = Colors.white.withOpacity(0.93));
    final backTail = Path()
      ..moveTo(31, 58)
      ..lineTo(28, 68)
      ..lineTo(40, 59)
      ..close();
    canvas.drawPath(backTail, Paint()..color = Colors.white.withOpacity(0.93));

    // dots inside the back bubble
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
        Offset(38 + i * 8.0, 45),
        2.1,
        Paint()..color = FcColors.indigoDeep.withOpacity(0.75),
      );
    }

    // --- front bubble (mint, overlapping) ----------------------------------
    final front = RRect.fromRectAndRadius(
      const Rect.fromLTWH(44, 46, 34, 24),
      const Radius.circular(10),
    );
    // A dark gap makes the overlap read at small sizes.
    canvas.drawRRect(
      front.inflate(2.6),
      Paint()
        ..color = showPlate ? const Color(0xFF2A1D63) : FcColors.midnight
        ..style = PaintingStyle.fill,
    );
    canvas.drawRRect(
      front,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [FcColors.mintSoft, FcColors.mint],
        ).createShader(const Rect.fromLTWH(44, 46, 34, 24)),
    );
    final frontTail = Path()
      ..moveTo(66, 68)
      ..lineTo(72, 74)
      ..lineTo(62, 69.5)
      ..close();
    canvas.drawPath(frontTail, Paint()..color = FcColors.mint);
    canvas.drawLine(
      const Offset(52, 58),
      const Offset(70, 58),
      Paint()
        ..color = FcColors.midnight.withOpacity(0.55)
        ..strokeWidth = 2
        ..strokeCap = StrokeCap.round,
    );

    // --- secure node network ------------------------------------------------
    const nodes = [Offset(72, 18), Offset(86, 26), Offset(76, 36)];
    final linkPaint = Paint()
      ..color = FcColors.mintSoft.withOpacity(0.55)
      ..strokeWidth = 1.2;
    canvas.drawLine(nodes[0], nodes[1], linkPaint);
    canvas.drawLine(nodes[1], nodes[2], linkPaint);
    canvas.drawLine(nodes[0], nodes[2], linkPaint);
    for (final node in nodes) {
      canvas.drawCircle(node, 2.6, Paint()..color = FcColors.mintSoft);
      canvas.drawCircle(
        node,
        4.6,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.9
          ..color = FcColors.mint.withOpacity(0.4),
      );
    }

    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _LogoPainter oldDelegate) => oldDelegate.showPlate != showPlate;
}

/// Wordmark: "Friend" in white, "Chat" in indigo, plus the mark.
class FriendChatWordmark extends StatelessWidget {
  const FriendChatWordmark({super.key, this.markSize = 34, this.fontSize = 22});

  final double markSize;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        FriendChatLogo(size: markSize, glow: false),
        const SizedBox(width: 10),
        RichText(
          text: TextSpan(
            children: [
              TextSpan(
                text: 'Friend',
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: FcColors.text,
                ),
              ),
              TextSpan(
                text: 'Chat',
                style: TextStyle(
                  fontSize: fontSize,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.4,
                  color: FcColors.violetSoft,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// A soft aurora blob used behind onboarding screens.
class AuroraBackdrop extends StatelessWidget {
  const AuroraBackdrop({super.key, this.child});

  final Widget? child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        const Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(gradient: FcColors.auroraBackground),
          ),
        ),
        Positioned(
          top: -120,
          right: -80,
          child: _Blob(
            size: 300,
            colors: [FcColors.indigo.withOpacity(0.35), Colors.transparent],
          ),
        ),
        Positioned(
          bottom: -140,
          left: -100,
          child: _Blob(
            size: 320,
            colors: [FcColors.mint.withOpacity(0.16), Colors.transparent],
          ),
        ),
        if (child != null) Positioned.fill(child: child!),
      ],
    );
  }
}

class _Blob extends StatelessWidget {
  const _Blob({required this.size, required this.colors});

  final double size;
  final List<Color> colors;

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(colors: colors, radius: 0.55),
        ),
      ),
    );
  }
}

/// Deterministic pseudo-random dots for the "secure network" onboarding art.
class NodeField extends StatelessWidget {
  const NodeField({super.key, this.count = 18, this.seed = 7});

  final int count;
  final int seed;

  @override
  Widget build(BuildContext context) {
    return CustomPaint(painter: _NodeFieldPainter(count: count, seed: seed), size: Size.infinite);
  }
}

class _NodeFieldPainter extends CustomPainter {
  const _NodeFieldPainter({required this.count, required this.seed});

  final int count;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final random = math.Random(seed);
    final points = List<Offset>.generate(
      count,
      (_) => Offset(random.nextDouble() * size.width, random.nextDouble() * size.height),
    );

    final line = Paint()
      ..color = FcColors.violetSoft.withOpacity(0.10)
      ..strokeWidth = 0.8;
    for (var i = 0; i < points.length; i++) {
      for (var j = i + 1; j < points.length; j++) {
        if ((points[i] - points[j]).distance < size.width * 0.22) {
          canvas.drawLine(points[i], points[j], line);
        }
      }
    }
    for (final point in points) {
      canvas.drawCircle(point, 1.6, Paint()..color = FcColors.mint.withOpacity(0.35));
    }
  }

  @override
  bool shouldRepaint(covariant _NodeFieldPainter oldDelegate) =>
      oldDelegate.count != count || oldDelegate.seed != seed;
}