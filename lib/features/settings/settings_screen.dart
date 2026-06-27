import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/routes.dart';
import '../../shared/providers/locale_provider.dart';
import 'settings_widgets.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    const settingsBlue = Color(0xFF4D9EFE);
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;

    return Theme(
      data: theme.copyWith(
        colorScheme: theme.colorScheme.copyWith(primary: settingsBlue),
      ),
      child: Scaffold(
        appBar: AppBar(title: Text(s.tabSettings)),
        body: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 600),
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              children: [
            NavTile(
              icon: Icons.palette_outlined,
              title: s.settingsAppearance,
              subtitle: s.settingsAppearanceDesc,
              cardColor: cardColor, outlineColor: outlineColor, isDark: isDark, theme: theme,
              onTap: () => context.push(AppRoutes.settingsAppearance),
            ),
            const SizedBox(height: 12),
            NavTile(
              icon: Icons.api_rounded,
              title: s.apiConfig,
              subtitle: s.apiConfigDesc,
              cardColor: cardColor, outlineColor: outlineColor, isDark: isDark, theme: theme,
              onTap: () => context.push(AppRoutes.settingsApiConfig),
            ),
            const SizedBox(height: 12),
            NavTile(
              icon: Icons.auto_awesome_rounded,
              title: s.settingsOperations,
              subtitle: s.settingsOperationsDesc,
              cardColor: cardColor, outlineColor: outlineColor, isDark: isDark, theme: theme,
              onTap: () => context.push(AppRoutes.settingsOperations),
            ),
            const SizedBox(height: 12),
            NavTile(
              icon: Icons.more_horiz_rounded,
              title: s.settingsOther,
              subtitle: s.settingsOtherDesc,
              cardColor: cardColor, outlineColor: outlineColor, isDark: isDark, theme: theme,
              onTap: () => context.push(AppRoutes.settingsOther),
            ),
            const SizedBox(height: 12),
            NavTile(
              icon: Icons.bar_chart_rounded,
              title: s.settingsDev,
              subtitle: s.settingsDevDesc,
              cardColor: cardColor, outlineColor: outlineColor, isDark: isDark, theme: theme,
              onTap: () => context.push(AppRoutes.settingsDeveloper),
            ),
          ],
        ),
        ),
      ),
      ),
    );
  }
}
