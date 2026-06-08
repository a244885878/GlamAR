import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// GlamAR 视觉主题 — 暗色奢感 + 玫瑰金点缀。
abstract final class GlamARColors {
  static const ink = Color(0xFF08080A);
  static const obsidian = Color(0xFF121014);
  static const rose = Color(0xFFE8A0A8);
  static const roseDeep = Color(0xFFB85C6E);
  static const champagne = Color(0xFFF3E4D4);
  static const pearl = Color(0xFFFFF8F2);
  static const mesh = Color(0xFF7FFFD4);
  static const meshIris = Color(0xFFFFB4C8);
}

abstract final class GlamARTheme {
  /// 竖屏 16:9 画面比例（宽:高 = 9:16）。
  static const double portraitCameraAspectRatio = 9 / 16;

  static ThemeData dark() {
    const scheme = ColorScheme.dark(
      surface: GlamARColors.obsidian,
      onSurface: GlamARColors.pearl,
      primary: GlamARColors.rose,
      onPrimary: GlamARColors.ink,
      secondary: GlamARColors.champagne,
      onSecondary: GlamARColors.ink,
    );

    final displayFont = GoogleFonts.cormorantGaramondTextTheme();
    final bodyFont = GoogleFonts.outfitTextTheme();

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: GlamARColors.ink,
      textTheme: bodyFont.apply(
        bodyColor: GlamARColors.pearl,
        displayColor: GlamARColors.pearl,
      ).copyWith(
        displayLarge: displayFont.displayLarge?.copyWith(
          fontWeight: FontWeight.w300,
          letterSpacing: 2,
          color: GlamARColors.pearl,
        ),
        displayMedium: displayFont.displayMedium?.copyWith(
          fontWeight: FontWeight.w400,
          color: GlamARColors.champagne,
        ),
        titleLarge: bodyFont.titleLarge?.copyWith(
          fontWeight: FontWeight.w500,
          letterSpacing: 0.5,
        ),
        bodyMedium: bodyFont.bodyMedium?.copyWith(
          color: GlamARColors.champagne.withValues(alpha: 0.75),
          height: 1.5,
        ),
        labelLarge: bodyFont.labelLarge?.copyWith(
          fontWeight: FontWeight.w600,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}
