import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../state/app_session.dart';
import '../theme/friend_chat_theme.dart';

/// ---------------------------------------------------------------------------
/// Shared UI atoms. Every screen composes these so spacing, radii and colour
/// live in one place.
/// ---------------------------------------------------------------------------

class FcScaffold extends StatelessWidget {
  const FcScaffold({
    super.key,
    required this.child,
    this.appBar,
    this.bottomNavigationBar,
    this.floatingActionButton,
    this.padded = true,
    this.gradient = true,
  });

  final Widget child;
  final PreferredSizeWidget? appBar;
  final Widget? bottomNavigationBar;
  final Widget? floatingActionButton;
  final bool padded;
  final bool gradient;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: appBar,
      bottomNavigationBar: bottomNavigationBar,
      floatingActionButton: floatingActionButton,
      extendBodyBehindAppBar: false,
      body: Stack(
        children: [
          if (gradient)
            const Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Color(0xFF12101F), FcColors.midnight],
                    stops: [0, 0.45],
                  ),
                ),
              ),
            ),
          SafeArea(
            child: Padding(
              padding: padded ? const EdgeInsets.symmetric(horizontal: FcSpace.md) : EdgeInsets.zero,
              child: child,
            ),
          ),
        ],
      ),
    );
  }
}

class FcAvatar extends StatelessWidget {
  const FcAvatar({
    super.key,
    required this.name,
    this.size = 46,
    this.accentHex = '#4F46E5',
    this.isBusiness = false,
    this.showOnline = false,
  });

  final String name;
  final double size;
  final String accentHex;
  final bool isBusiness;
  final bool showOnline;

  @override
  Widget build(BuildContext context) {
    final accent = Color(parseHexColor(accentHex));
    final initials = _initials(name);

    return SizedBox(
      width: size,
      height: size,
      child: Stack(
        children: [
          Container(
            width: size,
            height: size,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(size * 0.34),
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [accent.withOpacity(0.95), FcColors.violet.withOpacity(0.85)],
              ),
              border: Border.all(color: Colors.white.withOpacity(0.10)),
              boxShadow: [
                BoxShadow(color: accent.withOpacity(0.25), blurRadius: size * 0.35, offset: const Offset(0, 4)),
              ],
            ),
            alignment: Alignment.center,
            child: Text(
              initials,
              style: TextStyle(
                fontSize: size * 0.36,
                fontWeight: FontWeight.w700,
                color: Colors.white,
                letterSpacing: 0.5,
              ),
            ),
          ),
          if (isBusiness)
            Positioned(
              right: -2,
              bottom: -2,
              child: Container(
                padding: EdgeInsets.all(size * 0.07),
                decoration: const BoxDecoration(color: FcColors.mint, shape: BoxShape.circle),
                child: Icon(Icons.storefront_rounded, size: size * 0.2, color: const Color(0xFF05271C)),
              ),
            ),
          if (showOnline)
            Positioned(
              right: 2,
              top: 2,
              child: Container(
                width: size * 0.24,
                height: size * 0.24,
                decoration: BoxDecoration(
                  color: FcColors.mint,
                  shape: BoxShape.circle,
                  border: Border.all(color: FcColors.midnight, width: 2),
                ),
              ),
            ),
        ],
      ),
    );
  }

  static String _initials(String name) {
    final parts = name.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, parts.first.length >= 2 ? 2 : 1).toUpperCase();
    return '${parts.first[0]}${parts.last[0]}'.toUpperCase();
  }
}

/// "On your Wi-Fi / Offline — showing cached messages" indicator.
class ConnectionPill extends StatelessWidget {
  const ConnectionPill({super.key, this.compact = false});

  final bool compact;

  @override
  Widget build(BuildContext context) {
    final session = context.watch<AppSession>();

    return ValueListenableBuilder<ConnectionInfo>(
      valueListenable: session.connection.info,
      builder: (context, info, _) {
        final (color, icon) = switch (info.status) {
          ConnectionStatus.online => (FcColors.mint, Icons.wifi_tethering_rounded),
          ConnectionStatus.degraded => (FcColors.warning, Icons.signal_wifi_statusbar_connected_no_internet_4_rounded),
          ConnectionStatus.connecting || ConnectionStatus.probing => (FcColors.violetSoft, Icons.sync_rounded),
          ConnectionStatus.offline => (FcColors.danger, Icons.cloud_off_rounded),
        };

        return Container(
          padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 12, vertical: compact ? 6 : 8),
          decoration: BoxDecoration(
            color: color.withOpacity(0.10),
            borderRadius: BorderRadius.circular(FcRadius.pill),
            border: Border.all(color: color.withOpacity(0.35)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: compact ? 13 : 15, color: color),
              const SizedBox(width: 6),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 200),
                child: Text(
                  info.label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: compact ? 11 : 12,
                    fontWeight: FontWeight.w600,
                    color: color,
                    letterSpacing: 0.1,
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class SectionHeader extends StatelessWidget {
  const SectionHeader({super.key, required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, FcSpace.lg, 4, FcSpace.sm),
      child: Row(
        children: [
          Expanded(child: Text(title.toUpperCase(), style: FcText.section)),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class FcCard extends StatelessWidget {
  const FcCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(FcSpace.md),
    this.onTap,
    this.borderColor,
    this.glow,
  });

  final Widget child;
  final EdgeInsets padding;
  final VoidCallback? onTap;
  final Color? borderColor;
  final Color? glow;

  @override
  Widget build(BuildContext context) {
    final content = Container(
      padding: padding,
      decoration: BoxDecoration(
        color: FcColors.surface,
        borderRadius: BorderRadius.circular(FcRadius.lg),
        border: Border.all(color: borderColor ?? FcColors.divider),
        boxShadow: glow == null
            ? null
            : [BoxShadow(color: glow!.withOpacity(0.18), blurRadius: 24, offset: const Offset(0, 8))],
      ),
      child: child,
    );

    if (onTap == null) return content;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(FcRadius.lg),
        child: content,
      ),
    );
  }
}

class LabelChip extends StatelessWidget {
  const LabelChip({super.key, required this.label, this.onTap, this.selected = false});

  final LabelTag label;
  final VoidCallback? onTap;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final color = Color(parseHexColor(label.colorHex));
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: color.withOpacity(selected ? 0.28 : 0.12),
          borderRadius: BorderRadius.circular(FcRadius.pill),
          border: Border.all(color: color.withOpacity(selected ? 0.9 : 0.4)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(selected ? Icons.check_rounded : Icons.sell_outlined, size: 12, color: color),
            const SizedBox(width: 6),
            Text(
              label.name,
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
            ),
          ],
        ),
      ),
    );
  }
}

class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.height = 56,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final double height;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;

    return Opacity(
      opacity: enabled ? 1 : 0.45,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(FcRadius.md),
          gradient: FcColors.primaryGradient,
          boxShadow: [
            BoxShadow(
              color: FcColors.indigo.withOpacity(enabled ? 0.35 : 0.1),
              blurRadius: 22,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: SizedBox(
          height: height,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(FcRadius.md),
              onTap: enabled ? onPressed : null,
              child: Center(
                child: loading
                    ? const SizedBox(
                        width: 22,
                        height: 22,
                        child: CircularProgressIndicator(strokeWidth: 2.2, color: Colors.white),
                      )
                    : Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (icon != null) ...[
                            Icon(icon, size: 19, color: Colors.white),
                            const SizedBox(width: 10),
                          ],
                          Text(
                            label,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Colors.white,
                              letterSpacing: 0.1,
                            ),
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

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.message, this.action});

  final IconData icon;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(FcSpace.xl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                color: FcColors.surfaceHigh,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: FcColors.divider),
              ),
              child: Icon(icon, size: 32, color: FcColors.violetSoft),
            ),
            const SizedBox(height: FcSpace.md),
            Text(title, style: FcText.title, textAlign: TextAlign.center),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, style: FcText.muted, textAlign: TextAlign.center),
            ],
            if (action != null) ...[
              const SizedBox(height: FcSpace.lg),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

/// Small "Business" / "Private" badge used in the app bar.
class FcBadge extends StatelessWidget {
  const FcBadge({super.key, required this.text, this.color = FcColors.mint});

  final String text;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.14),
        borderRadius: BorderRadius.circular(FcRadius.pill),
        border: Border.all(color: color.withOpacity(0.35)),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 0.5, color: color),
      ),
    );
  }
}