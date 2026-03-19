import 'package:flutter/material.dart';

class AppTheme {
  static const Color capriBlue = Color(0xFF00AEEF);
  static const Color deepSea = Color(0xFF10273F);
  static const Color mist = Color(0xFFF4F8FB);
  static const Color paper = Colors.white;
  static const Color dune = Color(0xFFEADFCF);

  static ThemeData get lightTheme {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary: capriBlue,
        onPrimary: Colors.white,
        secondary: dune,
        onSecondary: deepSea,
        surface: paper,
        onSurface: deepSea,
        outline: Color(0xFFD7E3EA),
        shadow: Color(0x200C3554),
      ),
      scaffoldBackgroundColor: mist,
      appBarTheme: const AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: deepSea,
      ),
      cardTheme: CardThemeData(
        color: paper,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: deepSea,
        foregroundColor: Colors.white,
        extendedTextStyle: TextStyle(fontWeight: FontWeight.w600),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0xFFD7E3EA)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: Color(0xFFD7E3EA)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: capriBlue, width: 1.4),
        ),
        filled: true,
        fillColor: paper,
        labelStyle: const TextStyle(
          color: Color(0xFF537082),
          fontWeight: FontWeight.w500,
        ),
        hintStyle: const TextStyle(color: Color(0xFF7E97A5)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: paper,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: const BorderSide(color: Color(0xFFD7E3EA)),
        labelStyle: const TextStyle(
          color: deepSea,
          fontWeight: FontWeight.w500,
        ),
      ),
      dividerColor: const Color(0xFFD7E3EA),
    );

    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontFamily: 'Georgia',
          fontWeight: FontWeight.w700,
          color: deepSea,
          letterSpacing: -0.6,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontFamily: 'Georgia',
          fontWeight: FontWeight.w700,
          color: deepSea,
          letterSpacing: -0.4,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: deepSea,
          letterSpacing: -0.2,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: deepSea,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          color: deepSea,
          height: 1.35,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          color: const Color(0xFF4A6678),
          height: 1.4,
        ),
      ),
    );
  }
}
