import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/routes.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/settings_providers.dart';
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
            // ── Account entry (prominent, darker) ──
            _AccountCard(
              title: s.settingsAccount,
              subtitle: '${ref.watch(usageDaysProvider)} ${s.daysN} · ${ref.watch(articlesCountProvider)} ${s.entriesN}',
              isDark: isDark,
              theme: theme,
              onTap: () => context.push(AppRoutes.settingsAccount),
            ),
            const SizedBox(height: 16),
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

/// Account entry card with darker background, shown at the top of settings.
class _AccountCard extends StatelessWidget {
  final String title;
  final String subtitle;
  final bool isDark;
  final ThemeData theme;
  final VoidCallback onTap;

  const _AccountCard({
    required this.title,
    required this.subtitle,
    required this.isDark,
    required this.theme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: LinearGradient(
              colors: isDark
                  ? [const Color(0xFF1E3A5F), const Color(0xFF15273F)]
                  : [const Color(0xFF0D2137), const Color(0xFF163455)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 48, height: 48,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Icon(Icons.person_rounded, size: 26, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleLarge?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    )),
                    const SizedBox(height: 3),
                    Text(subtitle, style: theme.textTheme.bodySmall?.copyWith(
                      color: Colors.white.withValues(alpha: 0.65),
                    )),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
