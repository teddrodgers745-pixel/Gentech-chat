import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';

class Palette {
  final String id;
  final String name;
  final Brightness brightness;
  final Color bg;
  final Color surface;
  final Color text;
  final Color muted;
  final Color accent;
  final Color userBg;
  final Color codeBg;
  final Color border;

  const Palette({
    required this.id,
    required this.name,
    required this.brightness,
    required this.bg,
    required this.surface,
    required this.text,
    required this.muted,
    required this.accent,
    required this.userBg,
    required this.codeBg,
    required this.border,
  });

  bool get isDark => brightness == Brightness.dark;
}

const List<Palette> palettes = [
  Palette(
    id: 'light',
    name: 'Светлая',
    brightness: Brightness.light,
    bg: Color(0xFFFBFAF8),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF26231F),
    muted: Color(0xFF7A746C),
    accent: Color(0xFFC2693A),
    userBg: Color(0xFFF0ECE4),
    codeBg: Color(0xFFF3F1EC),
    border: Color(0xFFE4DFD6),
  ),
  Palette(
    id: 'dark',
    name: 'Тёмная',
    brightness: Brightness.dark,
    bg: Color(0xFF1B1A18),
    surface: Color(0xFF242320),
    text: Color(0xFFE8E4DC),
    muted: Color(0xFF9A948A),
    accent: Color(0xFFE0915F),
    userBg: Color(0xFF2B2926),
    codeBg: Color(0xFF121110),
    border: Color(0xFF38352F),
  ),
  Palette(
    id: 'sepia',
    name: 'Книжная',
    brightness: Brightness.light,
    bg: Color(0xFFF4ECD8),
    surface: Color(0xFFF9F3E3),
    text: Color(0xFF3B3226),
    muted: Color(0xFF85755E),
    accent: Color(0xFF9C5B2E),
    userBg: Color(0xFFEBE0C6),
    codeBg: Color(0xFFEAE0C8),
    border: Color(0xFFD9CCAB),
  ),
  Palette(
    id: 'amoled',
    name: 'AMOLED',
    brightness: Brightness.dark,
    bg: Color(0xFF000000),
    surface: Color(0xFF0B0B0B),
    text: Color(0xFFDCDCDC),
    muted: Color(0xFF8A8A8A),
    accent: Color(0xFFE0915F),
    userBg: Color(0xFF151515),
    codeBg: Color(0xFF0E0E0E),
    border: Color(0xFF262626),
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

/// Стиль текста выбранным шрифтом Google Fonts.
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

  TextTheme textTheme = base.textTheme;
  try {
    textTheme = GoogleFonts.getTextTheme('Inter', base.textTheme);
  } catch (_) {}

  return base.copyWith(
    textTheme: textTheme.apply(bodyColor: p.text, displayColor: p.text),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      foregroundColor: p.text,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      systemOverlayStyle:
          p.isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
    ),
    drawerTheme: DrawerThemeData(backgroundColor: p.surface),
    dividerColor: p.border,
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.text,
      contentTextStyle: TextStyle(color: p.bg),
      behavior: SnackBarBehavior.floating,
    ),
  );
}
