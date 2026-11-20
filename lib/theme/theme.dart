import 'package:flutter/material.dart';

import 'tokens.dart';

/// Accent focus ring: 3 px, accent at 55% (design/DESIGN.md "keyboard focus rings in accent").
BorderSide focusRing(AppColors c) => BorderSide(color: c.accent.withValues(alpha: .55), width: 3);

ThemeData buildTheme(Brightness b) {
  final c = b == Brightness.dark ? AppColors.dark : AppColors.light;
  final base = ThemeData(
    brightness: b,
    useMaterial3: true,
    colorScheme: ColorScheme.fromSeed(seedColor: c.accent, brightness: b).copyWith(
      primary: c.accent,
      onPrimary: c.onAccent,
      surface: c.background,
      onSurface: c.text,
      error: c.error,
      outline: c.divider,
    ),
    scaffoldBackgroundColor: c.background,
    dividerColor: c.divider,
    splashFactory: NoSplash.splashFactory,
    highlightColor: Colors.transparent,
    hoverColor: Colors.transparent,
    focusColor: Colors.transparent,
    visualDensity: VisualDensity.compact,
  );
  final text = base.textTheme.apply(bodyColor: c.text, displayColor: c.text);
  const tabular = [FontFeature.tabularFigures()];
  RoundedRectangleBorder shape(double r, [BorderSide side = BorderSide.none]) =>
      RoundedRectangleBorder(borderRadius: BorderRadius.circular(r), side: side);
  OutlineInputBorder border(Color color, double width) => OutlineInputBorder(
        borderRadius: BorderRadius.circular(Radii.field),
        borderSide: BorderSide(color: color, width: width),
      );
  final labelStyle = TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600, color: c.text);

  return base.copyWith(
    textTheme: text.copyWith(
      bodyMedium: text.bodyMedium?.copyWith(fontSize: TypeSize.body, fontFeatures: tabular),
      bodyLarge: text.bodyLarge?.copyWith(fontSize: TypeSize.body),
      bodySmall: text.bodySmall?.copyWith(fontSize: TypeSize.caption, color: c.textSecondary, fontFeatures: tabular),
      labelLarge: labelStyle,
      labelMedium: text.labelMedium?.copyWith(fontSize: TypeSize.label, fontWeight: FontWeight.w600, color: c.textTertiary),
      titleLarge: text.titleLarge?.copyWith(fontSize: TypeSize.headline, fontWeight: FontWeight.w700, letterSpacing: -.3),
      titleMedium: text.titleMedium?.copyWith(fontSize: TypeSize.body, fontWeight: FontWeight.w600),
      headlineMedium: text.headlineMedium?.copyWith(fontSize: TypeSize.setupTitle, fontWeight: FontWeight.w700, letterSpacing: -.5),
    ),
    textSelectionTheme: TextSelectionThemeData(cursorColor: c.accent, selectionColor: c.accentSoft),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: c.field,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      hintStyle: TextStyle(color: c.textTertiary),
      border: border(c.divider, 1),
      enabledBorder: border(c.divider, 1),
      focusedBorder: border(c.accent, 1.5),
      errorBorder: border(c.error, 1),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.disabled)
            ? c.accent.withValues(alpha: .35)
            : s.contains(WidgetState.pressed) || s.contains(WidgetState.hovered)
                ? c.accentPressed
                : c.accent),
        foregroundColor: WidgetStatePropertyAll(c.onAccent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(shape(Radii.button)),
        side: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? focusRing(c) : BorderSide.none),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18, vertical: 8)),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600)),
        animationDuration: Motion.control,
      ),
    ),
    // Quiet bordered button for everything that is not the one primary action.
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.pressed) ? c.divider : c.field),
        foregroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.disabled) ? c.textTertiary : c.text),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(shape(Radii.button)),
        side: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? focusRing(c) : BorderSide(color: c.divider)),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 18, vertical: 8)),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600)),
        animationDuration: Motion.control,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(c.accent),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        shape: WidgetStatePropertyAll(shape(Radii.button)),
        side: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? focusRing(c) : BorderSide.none),
        textStyle: const WidgetStatePropertyAll(TextStyle(fontSize: TypeSize.body, fontWeight: FontWeight.w600)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        foregroundColor: WidgetStatePropertyAll(c.text),
        overlayColor: const WidgetStatePropertyAll(Colors.transparent),
        side: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.focused) ? focusRing(c) : BorderSide.none),
      ),
    ),
    // Approximation for anyone still using SegmentedButton; lib/theme/segmented.dart is the real look.
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        backgroundColor: WidgetStateProperty.resolveWith(
            (s) => s.contains(WidgetState.selected) ? c.background : c.field),
        foregroundColor: WidgetStatePropertyAll(c.text),
        side: WidgetStatePropertyAll(BorderSide(color: c.divider)),
        shape: WidgetStatePropertyAll(shape(Radii.segmented)),
        textStyle: WidgetStateProperty.resolveWith((s) => TextStyle(
            fontSize: TypeSize.body, fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w400)),
      ),
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: c.accent, linearTrackColor: c.divider),
    dividerTheme: DividerThemeData(color: c.divider, space: 1, thickness: 1),
    tooltipTheme: TooltipThemeData(
      textStyle: TextStyle(fontSize: TypeSize.caption, color: c.background),
      decoration: BoxDecoration(color: c.text, borderRadius: BorderRadius.circular(Radii.artwork)),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: c.background,
      surfaceTintColor: Colors.transparent,
      shape: shape(Radii.button, BorderSide(color: c.divider)),
      textStyle: TextStyle(fontSize: TypeSize.body, color: c.text),
    ),
    scrollbarTheme: ScrollbarThemeData(thumbColor: WidgetStatePropertyAll(c.textTertiary.withValues(alpha: .5))),
  );
}
