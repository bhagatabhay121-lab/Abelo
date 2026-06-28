import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Palette restyled to match the "Joytify" UI reference (ui_design screenshots):
/// near-black backgrounds, a single hot-pink accent, bold white headlines and
/// muted grey secondary text. Names are kept the same as the original Taar
/// theme (marigold/jade/vermilion etc.) so every existing screen picks up
/// the new look automatically — only the hex values changed.
class TaarColors {
  // Backgrounds
  static const ink = Color(0xFF121212); // app background
  static const ink2 = Color(0xFF1E1E1E); // cards, search bar, sheets
  static const ink3 = Color(0xFF262626); // elevated surfaces / skeletons
  static const line = Color(0xFF2C2C2C); // hairline borders/dividers

  // Text
  static const cream = Color(0xFFFFFFFF); // primary text (was off-white)
  static const creamDim = Color(0xFF9E9E9E); // secondary text

  // Accent — repurposed from gold to the Joytify hot-pink (#C51162)
  static const marigold = Color(0xFFC51162); // primary accent / CTA pink
  static const marigoldDim = Color(0xFF8C0E47); // pressed/dim pink
  static const pinkPillBg = Color(0xFF24121A); // active bottom-nav pill fill

  // Secondary accents (kept for shuffle/repeat-on states etc.)
  static const jade = Color(0xFF3F7A6A);
  static const jadeBright = Color(0xFFFF4D94); // bright pink for "on" toggles
  static const vermilion = Color(0xFFFF2D78); // liked-heart fill

  // Light theme variant (data-theme="light")
  static const inkLight = Color(0xFFFAF6F7);
  static const ink2Light = Color(0xFFF1E9EC);
  static const ink3Light = Color(0xFFE7DDE1);
  static const lineLight = Color(0xFFDDCDD3);
  static const creamLight = Color(0xFF1A1A1A);
  static const creamDimLight = Color(0xFF73666B);
}

class TaarTheme {
  static ThemeData dark() => _build(
        bg: TaarColors.ink,
        surface: TaarColors.ink2,
        surface2: TaarColors.ink3,
        line: TaarColors.line,
        text: TaarColors.cream,
        textDim: TaarColors.creamDim,
        brightness: Brightness.dark,
      );

  static ThemeData light() => _build(
        bg: TaarColors.inkLight,
        surface: TaarColors.ink2Light,
        surface2: TaarColors.ink3Light,
        line: TaarColors.lineLight,
        text: TaarColors.creamLight,
        textDim: TaarColors.creamDimLight,
        brightness: Brightness.light,
      );

  static ThemeData _build({
    required Color bg,
    required Color surface,
    required Color surface2,
    required Color line,
    required Color text,
    required Color textDim,
    required Brightness brightness,
  }) {
    final textTheme = GoogleFonts.interTextTheme().apply(
      bodyColor: text,
      displayColor: text,
    );
    return ThemeData(
      brightness: brightness,
      scaffoldBackgroundColor: bg,
      canvasColor: bg,
      primaryColor: TaarColors.marigold,
      colorScheme: ColorScheme(
        brightness: brightness,
        primary: TaarColors.marigold,
        onPrimary: Colors.white,
        secondary: TaarColors.jadeBright,
        onSecondary: Colors.white,
        error: TaarColors.vermilion,
        onError: Colors.white,
        surface: surface,
        onSurface: text,
      ),
      textTheme: textTheme,
      fontFamily: GoogleFonts.inter().fontFamily,
      appBarTheme: AppBarTheme(
        backgroundColor: bg,
        foregroundColor: text,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      bottomNavigationBarTheme: BottomNavigationBarThemeData(
        backgroundColor: surface,
        selectedItemColor: TaarColors.marigold,
        unselectedItemColor: textDim,
        type: BottomNavigationBarType.fixed,
      ),
      dividerColor: line,
      iconTheme: IconThemeData(color: text),
      sliderTheme: SliderThemeData(
        activeTrackColor: TaarColors.marigold,
        inactiveTrackColor: line,
        thumbColor: TaarColors.marigold,
        overlayColor: TaarColors.marigold.withOpacity(0.15),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: surface,
        hintStyle: TextStyle(color: textDim),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(99),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(99),
          borderSide: BorderSide.none,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(99),
          borderSide: const BorderSide(color: TaarColors.marigoldDim),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      ),
    );
  }

  /// Bold geometric display style — mirrors the chunky rounded headline
  /// font used throughout the Joytify reference screens.
  static TextStyle display(BuildContext context, {double size = 22, FontWeight weight = FontWeight.w700}) =>
      GoogleFonts.poppins(fontSize: size, fontWeight: weight, color: Theme.of(context).textTheme.bodyLarge?.color);

  /// Pink, bold section-header style ("Celebrating Father's Day",
  /// "Trending community playlists", etc. in the reference screens).
  static TextStyle sectionHeader(BuildContext context, {double size = 18}) =>
      GoogleFonts.poppins(fontSize: size, fontWeight: FontWeight.w700, color: TaarColors.marigold);
}
