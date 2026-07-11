import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class AppTheme {
  static const Color seaFace = Color(0xFF00AEEF);
  static const Color deepSea = Color(0xFF10273F);
  static const Color mist = Color(0xFFF4F8FB);
  static const Color paper = Colors.white;
  static const Color dune = Color(0xFFEADFCF);

  // ---------- LIGHT THEME ----------
  static ThemeData get lightTheme {
    final base = ThemeData(
      useMaterial3: true,
      colorScheme: const ColorScheme.light(
        primary: seaFace,
        onPrimary: Colors.white,
        secondary: dune,
        onSecondary: deepSea,
        surface: paper,
        onSurface: deepSea,
        outline: Color(0xFFD7E3EA),
        shadow: Color(0x200C3554),
      ),
      scaffoldBackgroundColor: mist,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: deepSea,
        systemOverlayStyle: SystemUiOverlayStyle.dark,
      ),
      cardTheme: CardThemeData(
        color: paper,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: deepSea,
        foregroundColor: Colors.white,
        elevation: 0,
        highlightElevation: 0,
        extendedTextStyle: TextStyle(fontWeight: FontWeight.w600),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          elevation: WidgetStatePropertyAll(0),
          shadowColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          elevation: WidgetStatePropertyAll(0),
          shadowColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          elevation: WidgetStatePropertyAll(0),
          shadowColor: WidgetStatePropertyAll(Colors.transparent),
        ),
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
          borderSide: const BorderSide(color: seaFace, width: 1.4),
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
      snackBarTheme: const SnackBarThemeData(
        showCloseIcon: true,
        behavior: SnackBarBehavior.floating,
      ),
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

  // ---------- DARK THEME ----------
  static const Color _darkSurface = Color(0xFF121A22);
  static const Color _darkCard = Color(0xFF1A2530);
  static const Color _darkOnSurface = Color(0xFFE0E8EE);
  static const Color _darkOutline = Color(0xFF2A3A48);
  static const Color _darkSubtext = Color(0xFF8FA3B1);

  static ThemeData get darkTheme {
    final base = ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: seaFace,
        onPrimary: Colors.white,
        secondary: Color(0xFF3A3024),
        onSecondary: _darkOnSurface,
        surface: _darkCard,
        onSurface: _darkOnSurface,
        outline: _darkOutline,
        shadow: Color(0x40000000),
      ),
      scaffoldBackgroundColor: _darkSurface,
      appBarTheme: AppBarTheme(
        centerTitle: true,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: Colors.transparent,
        foregroundColor: _darkOnSurface,
        systemOverlayStyle: SystemUiOverlayStyle.light,
      ),
      cardTheme: CardThemeData(
        color: _darkCard,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: seaFace,
        foregroundColor: Colors.white,
        elevation: 0,
        highlightElevation: 0,
        extendedTextStyle: TextStyle(fontWeight: FontWeight.w600),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: ButtonStyle(
          elevation: WidgetStatePropertyAll(0),
          shadowColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: ButtonStyle(
          elevation: WidgetStatePropertyAll(0),
          shadowColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: ButtonStyle(
          elevation: WidgetStatePropertyAll(0),
          shadowColor: WidgetStatePropertyAll(Colors.transparent),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: _darkOutline),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: _darkOutline),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(20),
          borderSide: const BorderSide(color: seaFace, width: 1.4),
        ),
        filled: true,
        fillColor: _darkCard,
        labelStyle: const TextStyle(
          color: _darkSubtext,
          fontWeight: FontWeight.w500,
        ),
        hintStyle: const TextStyle(color: _darkSubtext),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: _darkCard,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        side: const BorderSide(color: _darkOutline),
        labelStyle: const TextStyle(
          color: _darkOnSurface,
          fontWeight: FontWeight.w500,
        ),
      ),
      dividerColor: _darkOutline,
      snackBarTheme: const SnackBarThemeData(
        showCloseIcon: true,
        behavior: SnackBarBehavior.floating,
      ),
    );

    return base.copyWith(
      textTheme: base.textTheme.copyWith(
        headlineLarge: base.textTheme.headlineLarge?.copyWith(
          fontFamily: 'Georgia',
          fontWeight: FontWeight.w700,
          color: _darkOnSurface,
          letterSpacing: -0.6,
        ),
        headlineMedium: base.textTheme.headlineMedium?.copyWith(
          fontFamily: 'Georgia',
          fontWeight: FontWeight.w700,
          color: _darkOnSurface,
          letterSpacing: -0.4,
        ),
        titleLarge: base.textTheme.titleLarge?.copyWith(
          fontWeight: FontWeight.w700,
          color: _darkOnSurface,
          letterSpacing: -0.2,
        ),
        titleMedium: base.textTheme.titleMedium?.copyWith(
          fontWeight: FontWeight.w600,
          color: _darkOnSurface,
        ),
        bodyLarge: base.textTheme.bodyLarge?.copyWith(
          color: _darkOnSurface,
          height: 1.35,
        ),
        bodyMedium: base.textTheme.bodyMedium?.copyWith(
          color: _darkSubtext,
          height: 1.4,
        ),
      ),
    );
  }
}

