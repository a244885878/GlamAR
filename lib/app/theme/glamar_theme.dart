import 'package:flutter/material.dart';

/// GlamAR 视觉主题 — 暗色奢感 + 玫瑰金点缀。
abstract final class GlamARColors {
  static const ink = Color(0xFF08080A);
  static const obsidian = Color(0xFF121014);
  static const rose = Color(0xFFE8A0A8);
  static const roseDeep = Color(0xFFB85C6E);
  static const champagne = Color(0xFFF3E4D4);
  static const pearl = Color(0xFFFFF8F2);
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

    // All production data is local. System fonts avoid runtime downloads and
    // keep Chinese title colors/metrics deterministic while offline.
    const bodyFont = TextTheme();
    const displayFont = TextTheme();

    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: scheme,
      scaffoldBackgroundColor: GlamARColors.ink,
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Color(0xF01B171C),
        contentTextStyle: TextStyle(
          color: GlamARColors.pearl,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
        actionTextColor: GlamARColors.rose,
        behavior: SnackBarBehavior.floating,
      ),
      textTheme: bodyFont
          .apply(
            bodyColor: GlamARColors.pearl,
            displayColor: GlamARColors.pearl,
          )
          .copyWith(
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
