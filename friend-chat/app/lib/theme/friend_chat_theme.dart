import 'package:flutter/material.dart';

/// ---------------------------------------------------------------------------
/// Friend Chat design tokens.
///
/// Midnight base, electric indigo primary, mint for "alive" states. Every
/// colour used anywhere in the app comes from this file, so the whole product
/// can be re-skinned from one place.
/// ---------------------------------------------------------------------------
abstract final class FcColors {
  // canvas
  static const midnight = Color(0xFF0B0B14);
  static const night = Color(0xFF10101B);
  static const surface = Color(0xFF161624);
  static const surfaceHigh = Color(0xFF1E1E2E);
  static const surfaceGlass = Color(0xFF20203A);

  // primary - electric indigo / neon violet
  static const indigo = Color(0xFF6366F1);
  static const indigoDeep = Color(0xFF4F46E5);
  static const violet = Color(0xFF8B5CF6);
  static const violetSoft = Color(0xFFA78BFA);

  // highlights - soft mint for active / online / delivered
  static const mint = Color(0xFF34D399);
  static const mintSoft = Color(0xFF6EE7B7);
  static const mintDim = Color(0xFF10503C);

  // text
  static const text = Color(0xFFF4F4FF);
  static const textMuted = Color(0xFF9E9EB8);
  static const textFaint = Color(0xFF6C6C86);

  // lines + states
  static const divider = Color(0xFF262636);
  static const danger = Color(0xFFFB7185);
  static const warning = Color(0xFFFBBF24);
  static const bubbleIn = Color(0xFF1B1B2A);
  static const bubbleInBorder = Color(0xFF27273A);

  static const indigoGlow = Color(0x336366F1);
  static const mintGlow = Color(0x3334D399);

  static const primaryGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
  );

  static const outgoingGradient = LinearGradient(
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
    colors: [Color(0xFF4F46E5), Color(0xFF7C3AED)],
  );

  static const auroraBackground = RadialGradient(
    center: Alignment(-0.7, -0.8),
    radius: 1.4,
    colors: [Color(0xFF1B1740), Color(0xFF0B0B14)],
  );
}

abstract final class FcRadius {
  static const sm = 10.0;
  static const md = 16.0;
  static const lg = 22.0;
  static const xl = 28.0;
  static const pill = 999.0;
}

abstract final class FcSpace {
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 16.0;
  static const lg = 24.0;
  static const xl = 32.0;
}

abstract final class FcText {
  static const display = TextStyle(
    fontSize: 30,
    height: 1.15,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.6,
    color: FcColors.text,
  );
  static const title = TextStyle(
    fontSize: 20,
    fontWeight: FontWeight.w700,
    letterSpacing: -0.2,
    color: FcColors.text,
  );
  static const section = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    letterSpacing: 0.8,
    color: FcColors.textFaint,
  );
  static const body = TextStyle(fontSize: 15, height: 1.4, color: FcColors.text);
  static const muted = TextStyle(fontSize: 13, height: 1.35, color: FcColors.textMuted);
  static const caption = TextStyle(fontSize: 11.5, color: FcColors.textFaint);
  static const mono = TextStyle(
    fontFamily: 'monospace',
    fontSize: 13,
    letterSpacing: 1.2,
    color: FcColors.textMuted,
  );
}

ThemeData buildFriendChatTheme() {
  const scheme = ColorScheme.dark(
    primary: FcColors.indigo,
    onPrimary: Colors.white,
    primaryContainer: FcColors.indigoDeep,
    secondary: FcColors.mint,
    onSecondary: Color(0xFF04140E),
    secondaryContainer: FcColors.mintDim,
    surface: FcColors.surface,
    onSurface: FcColors.text,
    surfaceContainerHighest: FcColors.surfaceHigh,
    error: FcColors.danger,
    onError: Colors.white,
    outline: FcColors.divider,
  );

  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: scheme,
    scaffoldBackgroundColor: FcColors.midnight,
    canvasColor: FcColors.midnight,
    splashFactory: InkSparkle.splashFactory,
    appBarTheme: const AppBarTheme(
      backgroundColor: FcColors.midnight,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      centerTitle: false,
      titleTextStyle: FcText.title,
      iconTheme: IconThemeData(color: FcColors.text),
    ),
    dividerTheme: const DividerThemeData(color: FcColors.divider, thickness: 1, space: 1),
    cardTheme: CardTheme(
      color: FcColors.surface,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(FcRadius.lg),
        side: const BorderSide(color: FcColors.divider),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: FcColors.surfaceHigh,
      hintStyle: const TextStyle(color: FcColors.textFaint, fontSize: 15),
      contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 18),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FcRadius.md),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FcRadius.md),
        borderSide: const BorderSide(color: FcColors.divider),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FcRadius.md),
        borderSide: const BorderSide(color: FcColors.indigo, width: 1.6),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(FcRadius.md),
        borderSide: const BorderSide(color: FcColors.danger),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: FcColors.indigoDeep,
        foregroundColor: Colors.white,
        minimumSize: const Size.fromHeight(56),
        textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FcRadius.md)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: FcColors.violetSoft,
        textStyle: const TextStyle(fontWeight: FontWeight.w600),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: FcColors.surfaceHigh,
      contentTextStyle: FcText.body,
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FcRadius.md)),
    ),
    dialogTheme: DialogTheme(
      backgroundColor: FcColors.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(FcRadius.lg)),
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? FcColors.mint : FcColors.textFaint,
      ),
      trackColor: WidgetStateProperty.resolveWith(
        (states) => states.contains(WidgetState.selected) ? FcColors.mintDim : FcColors.surfaceHigh,
      ),
    ),
    progressIndicatorTheme: const ProgressIndicatorThemeData(color: FcColors.mint),
  );
}