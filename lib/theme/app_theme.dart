/// Application theme.
///
/// Single source of truth for the demo's Material 3 light + dark themes.
/// Both are seeded from a Stellar-aligned deep blue with a warm-orange
/// secondary so action surfaces (chips, badges, accents) read distinctly
/// against the primary navy.
library;

import 'package:flutter/material.dart';

/// Default visible duration for transient snackbar confirmations such as
/// "Copied" toasts.
const Duration snackBarDefaultDuration = Duration(seconds: 2);

/// Brand-aligned seed for the primary tonal palette.
const Color _stellarDeepBlue = Color(0xFF0B1F3A);

/// Warm orange used as the secondary accent in both light and dark schemes.
const Color _stellarWarmOrange = Color(0xFFE94B22);

/// Builds the light [ThemeData] for the demo.
ThemeData buildLightTheme() => _buildTheme(Brightness.light);

/// Builds the dark [ThemeData] for the demo.
ThemeData buildDarkTheme() => _buildTheme(Brightness.dark);

ThemeData _buildTheme(Brightness brightness) {
  final ColorScheme base = ColorScheme.fromSeed(
    seedColor: _stellarDeepBlue,
    brightness: brightness,
  );

  // Override the secondary family so the warm orange shows through chips,
  // selected states, and accent ribbons rather than being recomputed away by
  // the seed-based tonal generator.
  final ColorScheme scheme = base.copyWith(
    secondary: _stellarWarmOrange,
    onSecondary: Colors.white,
    secondaryContainer: brightness == Brightness.light
        ? const Color(0xFFFFE3D7)
        : const Color(0xFF6B2A14),
    onSecondaryContainer: brightness == Brightness.light
        ? const Color(0xFF3A0F00)
        : const Color(0xFFFFDBC9),
  );

  final TextTheme textTheme = _buildTextTheme(brightness, scheme);

  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    textTheme: textTheme,
    appBarTheme: AppBarTheme(
      backgroundColor: scheme.primary,
      foregroundColor: scheme.onPrimary,
      elevation: 0,
      scrolledUnderElevation: 0,
      surfaceTintColor: Colors.transparent,
      centerTitle: false,
      iconTheme: IconThemeData(color: scheme.onPrimary),
      actionsIconTheme: IconThemeData(color: scheme.onPrimary),
      titleTextStyle: textTheme.titleLarge?.copyWith(
        color: scheme.onPrimary,
        fontWeight: FontWeight.w600,
      ),
    ),
    cardTheme: CardThemeData(
      color: scheme.surfaceContainerLow,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: scheme.outlineVariant),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(64, 48),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        side: BorderSide(color: scheme.outline),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 15,
        ),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(48, 40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 14,
        ),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        foregroundColor: scheme.onSurfaceVariant,
      ),
    ),
    chipTheme: ChipThemeData(
      side: BorderSide(color: scheme.outlineVariant),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
      ),
      labelStyle: textTheme.labelSmall?.copyWith(
        fontWeight: FontWeight.w600,
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outline),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.outline),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 2),
      ),
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 14,
        vertical: 14,
      ),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
      ),
    ),
  );
}

TextTheme _buildTextTheme(Brightness brightness, ColorScheme scheme) {
  final base = brightness == Brightness.light
      ? Typography.material2021().black
      : Typography.material2021().white;
  return base.copyWith(
    displayLarge: base.displayLarge?.copyWith(fontWeight: FontWeight.w700),
    displayMedium: base.displayMedium?.copyWith(fontWeight: FontWeight.w700),
    displaySmall: base.displaySmall?.copyWith(fontWeight: FontWeight.w700),
    headlineLarge: base.headlineLarge?.copyWith(fontWeight: FontWeight.w700),
    headlineMedium: base.headlineMedium?.copyWith(fontWeight: FontWeight.w700),
    headlineSmall: base.headlineSmall?.copyWith(fontWeight: FontWeight.w600),
    titleLarge: base.titleLarge?.copyWith(fontWeight: FontWeight.w600),
    titleMedium: base.titleMedium?.copyWith(fontWeight: FontWeight.w600),
    titleSmall: base.titleSmall?.copyWith(fontWeight: FontWeight.w600),
    labelLarge: base.labelLarge?.copyWith(fontWeight: FontWeight.w600),
    labelMedium: base.labelMedium?.copyWith(fontWeight: FontWeight.w600),
  );
}
