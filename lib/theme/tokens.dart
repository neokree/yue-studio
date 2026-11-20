import 'package:flutter/widgets.dart';

/// Every colour, radius, spacing, type size and duration lives here (provisional until design/DESIGN.md lands).
class AppColors {
  const AppColors({
    required this.background,
    required this.sidebar,
    required this.surface,
    required this.text,
    required this.textSecondary,
    required this.divider,
    required this.accent,
    required this.onAccent,
    required this.success,
    required this.error,
    required this.selection,
  });

  final Color background;
  final Color sidebar; // translucent
  final Color surface;
  final Color text;
  final Color textSecondary;
  final Color divider;
  final Color accent;
  final Color onAccent;
  final Color success;
  final Color error;
  final Color selection;

  static const light = AppColors(
    background: Color(0xFFFFFFFF),
    sidebar: Color(0xCCF2EFEC),
    surface: Color(0xFFF6F4F2),
    text: Color(0xFF1D1B1A),
    textSecondary: Color(0xFF6E6965),
    divider: Color(0x1F000000),
    accent: Color(0xFFC8553D),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF2E8B57),
    error: Color(0xFFC0392B),
    selection: Color(0x1FC8553D),
  );

  static const dark = AppColors(
    background: Color(0xFF1C1B1A),
    sidebar: Color(0xCC2A2827),
    surface: Color(0xFF262423),
    text: Color(0xFFF3F0EE),
    textSecondary: Color(0xFFA09A95),
    divider: Color(0x1FFFFFFF),
    accent: Color(0xFFE0674E),
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF4CB782),
    error: Color(0xFFE5675A),
    selection: Color(0x33E0674E),
  );

  static AppColors of(BuildContext context) =>
      MediaQuery.platformBrightnessOf(context) == Brightness.dark ? dark : light;
}

class Radii {
  static const double sm = 6;
  static const double md = 10;
  static const double lg = 16;
}

class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16;
  static const double lg = 24;
  static const double xl = 40;
}

class TypeSize {
  static const double caption = 12;
  static const double body = 14;
  static const double title = 17;
  static const double headline = 28;
}

class Motion {
  static const fast = Duration(milliseconds: 120);
  static const normal = Duration(milliseconds: 240);
  static const slow = Duration(milliseconds: 480);
}

class Layout {
  static const double sidebarWidth = 200;
  static const double contentMaxWidth = 720;
}
