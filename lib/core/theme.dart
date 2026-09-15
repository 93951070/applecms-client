import 'package:flutter/material.dart';
import 'package:flutter/cupertino.dart';
import 'package:google_fonts/google_fonts.dart';

/// 融合设计规范：Appad 粉调 + Zen 玻璃
class AppColors {
  AppColors._();

  /// 主色：粉色（Tab 高亮、按钮、继续观看条）
  static const Color pink = Color(0xFFFF4D8D);
  static const Color pinkDeep = Color(0xFFE83A75);
  static const Color pinkLight = Color(0xFFFFE9F1);

  /// 语义色
  static const Color scoreGreen = Color(0xFF26C281);
  static const Color yearRed = Color(0xFFFF4D4F);
  static const Color vipGold = Color(0xFFFFB84D);
  static const Color vipGoldDeep = Color(0xFFFF7A00);

  /// 点缀蓝（极光背景）
  static const Color auroraBlue = Color(0xFF6AA6FF);
  static const Color auroraPurple = Color(0xFFB388FF);

  // 浅色文字层级
  static const Color lightText = Color(0xFF1A1A1A);
  static const Color lightText2 = Color(0xFF8A8A8E);
  static const Color lightText3 = Color(0xFFB8B8BC);

  // 深色文字层级
  static const Color darkText = Color(0xFFF5F5F7);
  static const Color darkText2 = Color(0xFFAEAEB2);
  static const Color darkText3 = Color(0xFF6E6E73);
}

class ZenTheme {
  // --- 玻璃与背景参数 ---
  static const double glassBlur = 20;

  static ThemeData lightTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      scaffoldBackgroundColor: const Color(0xFFF7F4F6),
      primaryColor: AppColors.pink,
      cardColor: Colors.white,
      dividerColor: const Color(0x1A000000),
      colorScheme: const ColorScheme.light(
        primary: AppColors.pink,
        onPrimary: Colors.white,
        secondary: AppColors.lightText2,
        surface: Colors.white,
        onSurface: AppColors.lightText,
        surfaceContainerHighest: Colors.white,
        outline: Color(0xFFE5E5EA),
      ),
      textTheme: _buildTextTheme(AppColors.lightText, AppColors.lightText2),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.lightText),
        titleTextStyle: TextStyle(
          color: AppColors.lightText,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.pink;
          return null;
        }),
      ),
    );
  }

  static ThemeData darkTheme() {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0E0A0D),
      primaryColor: AppColors.pink,
      cardColor: const Color(0xFF1C171B),
      dividerColor: const Color(0x1AFFFFFF),
      colorScheme: const ColorScheme.dark(
        primary: AppColors.pink,
        onPrimary: Colors.white,
        secondary: AppColors.darkText2,
        surface: Color(0xFF1C171B),
        onSurface: AppColors.darkText,
        surfaceContainerHighest: Color(0xFF2C262B),
        outline: Color(0xFF38383A),
      ),
      textTheme: _buildTextTheme(AppColors.darkText, AppColors.darkText2),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.macOS: CupertinoPageTransitionsBuilder(),
          TargetPlatform.android: CupertinoPageTransitionsBuilder(),
        },
      ),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        iconTheme: IconThemeData(color: AppColors.darkText),
        titleTextStyle: TextStyle(
          color: AppColors.darkText,
          fontSize: 20,
          fontWeight: FontWeight.bold,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return Colors.white;
          return null;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) return AppColors.pink;
          return null;
        }),
      ),
    );
  }

  // --- 字体设置 ---
  static TextTheme _buildTextTheme(Color primaryColor, Color secondaryColor) {
    final baseTheme = GoogleFonts.interTextTheme();
    return baseTheme.copyWith(
      displayLarge: GoogleFonts.inter(
        fontWeight: FontWeight.w800,
        color: primaryColor,
        letterSpacing: -1.0,
        fontSize: 32,
      ),
      displayMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w800,
        color: primaryColor,
        letterSpacing: -0.8,
        fontSize: 24,
      ),
      titleLarge: GoogleFonts.inter(
        fontWeight: FontWeight.bold,
        color: primaryColor,
        fontSize: 20,
      ),
      titleMedium: GoogleFonts.inter(
        fontWeight: FontWeight.w600,
        color: primaryColor,
        fontSize: 16,
      ),
      bodyLarge: GoogleFonts.inter(
        color: primaryColor,
        fontSize: 15,
      ),
      bodyMedium: GoogleFonts.inter(
        color: primaryColor.withValues(alpha: 0.8),
        fontSize: 14,
      ),
      labelMedium: GoogleFonts.inter(
        color: secondaryColor,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.5,
        fontSize: 12,
      ),
    );
  }
}

