import 'package:flutter/widgets.dart';

/// Every colour, radius, spacing, type size and duration lives here (design/DESIGN.md, approved 2026-11-20).
class AppColors {
  const AppColors({
    required this.background,
    required this.sidebar,
    required this.sidebarOpaque,
    required this.field,
    required this.text,
    required this.textSecondary,
    required this.textTertiary,
    required this.placeholder,
    required this.divider,
    required this.accent,
    required this.accentPressed,
    required this.accentSoft,
    required this.onAccent,
    required this.success,
    required this.error,
  });

  /// Window / content background.
  final Color background;

  /// Translucent sidebar tint, drawn over the macOS blur.
  final Color sidebar;

  /// Same colour without alpha, used where there is no blur behind it (Linux tests).
  final Color sidebarOpaque;

  /// Text fields, quiet buttons, segmented tracks.
  final Color field;
  final Color text;
  final Color textSecondary;
  final Color textTertiary;

  /// Input placeholder: a touch darker than textTertiary in light so it keeps 4.5:1 on the field colour.
  final Color placeholder;

  /// Hairlines (DESIGN "separator").
  final Color divider;
  final Color accent;
  final Color accentPressed;

  /// Selection, current nav item.
  final Color accentSoft;
  final Color onAccent;
  final Color success;
  final Color error;

  /// Older names kept so other tracks keep compiling.
  Color get surface => field;
  Color get selection => accentSoft;

  static const light = AppColors(
    background: Color(0xFFFFFFFF),
    sidebar: Color(0xD1F6F4F1), // #F6F4F1 at 82%
    sidebarOpaque: Color(0xFFF6F4F1),
    field: Color(0xFFF4F3F1),
    text: Color(0xFF1D1D1F),
    textSecondary: Color(0xFF5F5F64),
    textTertiary: Color(0xFF77777C),
    placeholder: Color(0xFF6C6C71),
    divider: Color(0x17000000), // black 9%
    accent: Color(0xFFA4503A),
    accentPressed: Color(0xFF8C4230),
    accentSoft: Color(0x1FA4503A), // 12%
    onAccent: Color(0xFFFFFFFF),
    success: Color(0xFF1F7A4A),
    error: Color(0xFFC0392B),
  );

  static const dark = AppColors(
    background: Color(0xFF1E1E20),
    sidebar: Color(0xC7282726), // #282726 at 78%
    sidebarOpaque: Color(0xFF282726),
    field: Color(0xFF2A2A2D),
    text: Color(0xFFF5F5F7),
    textSecondary: Color(0xFFB4B4BA),
    textTertiary: Color(0xFF98989E),
    placeholder: Color(0xFF98989E),
    divider: Color(0x1AFFFFFF), // white 10%
    accent: Color(0xFFD97C62),
    accentPressed: Color(0xFFE8927A),
    accentSoft: Color(0x2ED97C62), // 18%
    onAccent: Color(0xFF1B0F0B),
    success: Color(0xFF4CB782),
    error: Color(0xFFE5675A),
  );

  static AppColors of(BuildContext context) =>
      MediaQuery.platformBrightnessOf(context) == Brightness.dark ? dark : light;
}

class Radii {
  static const double window = 12;
  static const double field = 10;
  static const double button = 8;
  static const double segmented = 7;
  static const double artwork = 6;

  /// Older names kept so other tracks keep compiling.
  static const double sm = artwork;
  static const double md = field;
  static const double lg = window;
}

/// 4-pt grid.
class Space {
  static const double xs = 4;
  static const double sm = 8;
  static const double md = 16; // field gap
  static const double lg = 24;
  static const double xl = 40;

  /// Window content padding (22 x 28).
  static const double padV = 22;
  static const double padH = 28;
}

class TypeSize {
  static const double label = 11; // table headers, sidebar group labels
  static const double caption = 12; // secondary
  static const double body = 13; // body and controls
  static const double brand = 14;
  static const double title = 20; // song title in generation
  static const double headline = 22; // screen title
  static const double setupTitle = 26;
}

class Motion {
  /// ease-out exponential, cubic-bezier(.16, 1, .3, 1).
  static const curve = Cubic(.16, 1, .3, 1);

  /// Control states.
  static const control = Duration(milliseconds: 200);

  /// Screen transitions.
  static const screen = Duration(milliseconds: 450);

  static const fast = control;
  static const normal = control;
  static const slow = screen;

  /// Zero when the system asks to reduce motion.
  static Duration of(BuildContext context, Duration d) =>
      MediaQuery.maybeDisableAnimationsOf(context) == true ? Duration.zero : d;
}

class Layout {
  static const double sidebarWidth = 216;
  static const double contentMaxWidth = 720;
  static const EdgeInsets contentPadding = EdgeInsets.symmetric(horizontal: Space.padH, vertical: Space.padV);
}

/// Set by main() once macOS vibrancy is active; tests and Linux keep the opaque sidebar.
class Chrome {
  static bool vibrancy = false;
}
