import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'config/theme.dart';
import 'config/routes.dart';
import 'shared/providers/locale_provider.dart';
import 'shared/providers/settings_providers.dart';

class App extends ConsumerWidget {
  const App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    final fontSize = ref.watch(fontSizeProvider);
    final fontWeightIdx = ref.watch(fontWeightIndexProvider);
    final locale = ref.watch(localeProvider);

    // Derive a text scale factor relative to the default 14.0
    final textScaleFactor = fontSize / 14.0;

    // Map 0→w400, 1→w500, 2→w600, 3→w700
    final fw = FontWeight.values[(fontWeightIdx.clamp(0, 3) + 3).clamp(3, 6)];
    // Apply font weight + Google Fonts (Noto Sans for CJK coverage) to both themes.
    final light = AppTheme.lightTheme.copyWith(
      textTheme: GoogleFonts.notoSansTextTheme(
        _applyTextTheme(AppTheme.lightTheme.textTheme, fw),
      ),
    );
    final dark = AppTheme.darkTheme.copyWith(
      textTheme: GoogleFonts.notoSansTextTheme(
        _applyTextTheme(AppTheme.darkTheme.textTheme, fw),
      ),
    );

    return MaterialApp.router(
      title: 'Article-Hub',
      theme: light,
      darkTheme: dark,
      themeMode: themeMode,
      locale: locale,
      supportedLocales: const [
        Locale('en'),
        Locale('zh'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      routerConfig: appRouter,
      debugShowCheckedModeBanner: false,
      builder: (context, child) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return AnnotatedRegion<SystemUiOverlayStyle>(
          value: SystemUiOverlayStyle(
            statusBarColor: Colors.transparent,
            statusBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
            systemNavigationBarColor:
                isDark ? const Color(0xFF1A2530) : Colors.white,
            systemNavigationBarIconBrightness:
                isDark ? Brightness.light : Brightness.dark,
          ),
          child: MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: TextScaler.linear(textScaleFactor),
            ),
            child: child!,
          ),
        );
      },
    );
  }

  /// Recursively applies [fontWeight] to every [TextStyle] in [theme]'s text
  /// theme so that the user's font weight preference is reflected everywhere.
  TextTheme _applyTextTheme(TextTheme t, FontWeight fw) {
    return t.copyWith(
      displayLarge: t.displayLarge?.copyWith(fontWeight: fw),
      displayMedium: t.displayMedium?.copyWith(fontWeight: fw),
      displaySmall: t.displaySmall?.copyWith(fontWeight: fw),
      headlineLarge: t.headlineLarge?.copyWith(fontWeight: fw.value > 600 ? fw : FontWeight.w700),
      headlineMedium: t.headlineMedium?.copyWith(fontWeight: fw.value > 600 ? fw : FontWeight.w700),
      headlineSmall: t.headlineSmall?.copyWith(fontWeight: fw),
      titleLarge: t.titleLarge?.copyWith(fontWeight: fw.value > 600 ? fw : FontWeight.w700),
      titleMedium: t.titleMedium?.copyWith(fontWeight: fw.value > 500 ? fw : FontWeight.w600),
      titleSmall: t.titleSmall?.copyWith(fontWeight: fw),
      bodyLarge: t.bodyLarge?.copyWith(fontWeight: fw),
      bodyMedium: t.bodyMedium?.copyWith(fontWeight: fw),
      bodySmall: t.bodySmall?.copyWith(fontWeight: fw),
      labelLarge: t.labelLarge?.copyWith(fontWeight: fw),
      labelMedium: t.labelMedium?.copyWith(fontWeight: fw),
      labelSmall: t.labelSmall?.copyWith(fontWeight: fw),
    );
  }
}
