import 'package:flutter/material.dart';

import 'tokens.dart';

ThemeData buildTheme(Brightness b) {
  final c = b == Brightness.dark ? AppColors.dark : AppColors.light;
  final base = ThemeData(
    brightness: b,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: c.accent, brightness: b).copyWith(
      primary: c.accent,
      onPrimary: c.onAccent,
      surface: c.background,
      error: c.error,
    ),
    scaffoldBackgroundColor: c.background,
    dividerColor: c.divider,
  );
  final text = base.textTheme.apply(bodyColor: c.text, displayColor: c.text);
  return base.copyWith(
    textTheme: text.copyWith(
      bodyMedium: text.bodyMedium?.copyWith(fontSize: TypeSize.body),
      titleLarge: text.titleLarge?.copyWith(fontSize: TypeSize.headline, fontWeight: FontWeight.w700),
      titleMedium: text.titleMedium?.copyWith(fontSize: TypeSize.title, fontWeight: FontWeight.w600),
      bodySmall: text.bodySmall?.copyWith(fontSize: TypeSize.caption, color: c.textSecondary),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.md),
        borderSide: BorderSide.none,
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: c.accent,
        foregroundColor: c.onAccent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Radii.md)),
        padding: const EdgeInsets.symmetric(horizontal: Space.lg, vertical: Space.md),
      ),
    ),
  );
}
