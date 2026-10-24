// Copyright (c) 2026 Minkail. All rights reserved.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class Palette {
  final String id;
  final String name;
  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color card;
  final Color text;
  final Color muted;
  final Color accent;
  final Color userBg;
  final Color codeBg;
  final Color border;
  final Color divider;

  const Palette({
    required this.id,
    required this.name,
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.card,
    required this.text,
    required this.muted,
    required this.accent,
    required this.userBg,
    required this.codeBg,
    required this.border,
    required this.divider,
  });

  bool get isDark => brightness == Brightness.dark;
}

/// Чётко тёплая палитра: warm charcoal (#1B1A19) + copper (#D99A6C).
/// Все четыре темы в одной гамме.
const List<Palette> palettes = [
  // Тёмная (основная)
  Palette(
    id: 'dark',
    name: 'Тёмная',
    brightness: Brightness.dark,
    bg: const Color(0xFF1B1A19),
    surface: const Color(0xFF242321),
    card: const Color(0xFF2A2826),
    text: const Color(0xFFF5F0EB),
    muted: const Color(0xFFA8A096),
    accent: const Color(0xFFD99A6C),
    userBg: const Color(0xFF322F2C),
    codeBg: const Color(0xFF161514),
    border: const Color(0xFF3A3733),
    divider: const Color(0xFF33302C),
  ),
  // Светлая (тёплая, не белая)
  Palette(
    id: 'light',
    name: 'Светлая',
    brightness: Brightness.light,
    bg: const Color(0xFFFDFBF7),
    surface: const Color(0xFFFFFFFF),
    card: const Color(0xFFF5F2ED),
    text: const Color(0xFF2B2824),
    muted: const Color(0xFF8C857A),
    accent: const Color(0xFFC2784A),
    userBg: const Color(0xFFEFECE3),
    codeBg: const Color(0xFFF0EDE6),
    border: const Color(0xFFE8E3D9),
    divider: const Color(0xFFE0DBD0),
  ),
  // Книжная (сепия)
  Palette(
    id: 'sepia',
    name: 'Книжная',
    brightness: Brightness.light,
    bg: const Color(0xFFF4ECD8),
    surface: const Color(0xFFF9F3E3),
    card: const Color(0xFFF0E8D4),
    text: const Color(0xFF3B3226),
    muted: const Color(0xFF85755E),
    accent: const Color(0xFF9C5B2E),
    userBg: const Color(0xFFEBE0C6),
    codeBg: const Color(0xFFEAE0C8),
    border: const Color(0xFFD9CCAB),
    divider: const Color(0xFFD0C4B0),
  ),
  // AMOLED (чёрный, но тёплый акцент)
  Palette(
    id: 'amoled',
    name: 'AMOLED',
    brightness: Brightness.dark,
    bg: const Color(0xFF000000),
    surface: const Color(0xFF0D0D0D),
    card: const Color(0xFF151515),
    text: const Color(0xFFF5F0EB),
    muted: const Color(0xFF8A8A8A),
    accent: const Color(0xFFD99A6C),
    userBg: const Color(0xFF1A1A1A),
    codeBg: const Color(0xFF0A0A0A),
    border: const Color(0xFF2A2A2A),
    divider: const Color(0xFF1F1F1F),
  ),
];

const List<String> bodyFonts = [
  'Literata',
  'Inter',
  'Source Serif 4',
  'Lora',
  'Merriweather',
  'PT Serif',
  'PT Sans',
  'Noto Sans',
  'Open Sans',
  'Fira Sans',
  'IBM Plex Sans',
  'Roboto',
];

const List<String> codeFonts = [
  'JetBrains Mono',
  'Fira Code',
  'Source Code Pro',
  'Roboto Mono',
  'IBM Plex Mono',
];

/// Стиль текста выбранным шрифтом Google Fonts с fallback на системные.
/// Если шрифт недоступен, возвращается обычный стиль без падения.
TextStyle fontStyle(
  String family, {
  double? size,
  Color? color,
  double? height,
  FontWeight? weight,
}) {
  final base = TextStyle(
    fontSize: size,
    color: color,
    height: height,
    fontWeight: weight,
  );
  try {
    return GoogleFonts.getFont(family, textStyle: base);
  } catch (_) {
    return base;
  }
}

/// Стиль для основного текста ответов: Literata с fallback на serif.
TextStyle bodyStyle(Palette p, double size, double lineHeight) {
  return TextStyle(
    fontFamily: 'Literata',
    fontFamilyFallback: const ['serif'],
    fontSize: size,
    color: p.text,
    height: lineHeight,
  );
}

/// Стиль для кода: JetBrains Mono с fallback на monospace.
TextStyle codeStyle(Palette p, double size) {
  return TextStyle(
    fontFamily: 'JetBrains Mono',
    fontFamilyFallback: const ['monospace'],
    fontSize: size,
    color: p.text,
    height: 1.45,
  );
}

ThemeData buildTheme(Palette p) {
  final scheme = ColorScheme.fromSeed(
    seedColor: p.accent,
    brightness: p.brightness,
  ).copyWith(
    surface: p.bg,
    onSurface: p.text,
    primary: p.accent,
    outline: p.border,
  );

  final base = ThemeData(
    useMaterial3: true,
    brightness: p.brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
  );

  return base.copyWith(
    textTheme: base.textTheme.apply(bodyColor: p.text, displayColor: p.text),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle:
          p.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      titleTextStyle: TextStyle(
        fontSize: 18,
        fontWeight: FontWeight.w600,
        color: p.text,
        fontFamily: 'Literata',
        fontFamilyFallback: const ['serif'],
      ),
    ),
    drawerTheme: DrawerThemeData(
      backgroundColor: p.surface,
      scrimColor: p.isDark ? Colors.black87 : Colors.black54,
    ),
    cardTheme: CardThemeData(
      color: p.card,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: BorderSide(color: p.border, width: 1),
      ),
    ),
    dividerColor: p.divider,
    dividerTheme: DividerThemeData(
      color: p.divider,
      thickness: 1,
      space: 1,
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.card,
      contentTextStyle: TextStyle(color: p.text),
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      actionTextColor: p.accent,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      hintStyle: TextStyle(color: p.muted, fontSize: 16),
      labelStyle: TextStyle(color: p.muted, fontSize: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: p.border, width: 1),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: p.border, width: 1),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: BorderSide(color: p.accent, width: 2),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: Color(0xFFB3261E), width: 1),
      ),
      focusedErrorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(20),
        borderSide: const BorderSide(color: Color(0xFFB3261E), width: 2),
      ),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: p.surface,
      selectedColor: p.accent.withValues(alpha: 0.15),
      checkmarkColor: p.accent,
      side: BorderSide(color: p.border, width: 1),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      labelStyle: TextStyle(color: p.text, fontSize: 14),
      secondaryLabelStyle: TextStyle(color: p.accent, fontSize: 14),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      titleTextStyle: TextStyle(
        fontSize: 20,
        fontWeight: FontWeight.w700,
        color: p.text,
        fontFamily: 'Literata',
        fontFamilyFallback: const ['serif'],
      ),
      contentTextStyle: TextStyle(color: p.text, fontSize: 15),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      modalBackgroundColor: p.surface,
    ),
    floatingActionButtonTheme: FloatingActionButtonThemeData(
      backgroundColor: p.accent,
      foregroundColor: Colors.white,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
    iconTheme: IconThemeData(color: p.text, size: 22),
    primaryIconTheme: IconThemeData(color: p.accent, size: 22),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.accent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      ),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: ElevatedButton.styleFrom(
        backgroundColor: p.accent,
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.accent,
        side: BorderSide(color: p.accent, width: 1.5),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
      ),
    ),
  );
}
