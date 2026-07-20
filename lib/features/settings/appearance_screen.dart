import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/widgets/delayed_reveal.dart';
import 'settings_widgets.dart';

class AppearanceScreen extends ConsumerStatefulWidget {
  const AppearanceScreen({super.key});

  @override
  ConsumerState<AppearanceScreen> createState() => _AppearanceScreenState();
}

class _AppearanceScreenState extends ConsumerState<AppearanceScreen> {
  double? _draggingFontSize;
  double? _draggingWebZoom;

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;

    return Scaffold(
      appBar: AppBar(title: Text(s.settingsAppearance)),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('$e')),
        data: (settings) => DelayedReveal(
          delayMs: 40, beginOffset: const Offset(0, 0.035),
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SectionLabel(label: s.appearance, theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity, padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: cardColor, borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(s.themeMode, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 10),
                    Row(children: [
                      ThemeModeButton(icon: Icons.brightness_auto_rounded, label: s.system, isSelected: settings.themeModeIndex == 0, onTap: () => ref.read(settingsProvider.notifier).setThemeMode(0), theme: theme),
                      const SizedBox(width: 10),
                      ThemeModeButton(icon: Icons.light_mode_rounded, label: s.light, isSelected: settings.themeModeIndex == 1, onTap: () => ref.read(settingsProvider.notifier).setThemeMode(1), theme: theme),
                      const SizedBox(width: 10),
                      ThemeModeButton(icon: Icons.dark_mode_rounded, label: s.dark, isSelected: settings.themeModeIndex == 2, onTap: () => ref.read(settingsProvider.notifier).setThemeMode(2), theme: theme),
                    ]),
                    const SizedBox(height: 8),
                    Text(s.language, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Row(children: [
                      ThemeModeButton(icon: Icons.language_rounded, label: s.system, isSelected: settings.languageIndex == 0, onTap: () => ref.read(settingsProvider.notifier).setLanguage(0), theme: theme),
                      const SizedBox(width: 10),
                      ThemeModeButton(icon: Icons.translate_rounded, label: '中文', isSelected: settings.languageIndex == 1, onTap: () => ref.read(settingsProvider.notifier).setLanguage(1), theme: theme),
                      const SizedBox(width: 10),
                      ThemeModeButton(icon: Icons.translate_rounded, label: 'English', isSelected: settings.languageIndex == 2, onTap: () => ref.read(settingsProvider.notifier).setLanguage(2), theme: theme),
                    ]),
                  ]),
                ),
                const SizedBox(height: 14),
                SectionLabel(label: s.fontSizeSection, theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity, padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: cardColor, borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Icon(Icons.text_fields_rounded, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 10), Text(s.textSize, style: theme.textTheme.titleMedium),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                        child: Text('${(_draggingFontSize ?? settings.fontSize).round()}', style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Row(children: [
                      const Text('A', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                      Expanded(child: Slider(value: _draggingFontSize ?? settings.fontSize, min: 10, max: 24, divisions: 14,
                        label: (_draggingFontSize ?? settings.fontSize).round().toString(),
                        onChanged: (v) => setState(() => _draggingFontSize = v),
                        onChangeEnd: (v) { ref.read(settingsProvider.notifier).setFontSize(v); setState(() => _draggingFontSize = null); },
                      )),
                      const Text('A', style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600)),
                    ]),
                    const SizedBox(height: 8),
                    Text(s.preview, style: theme.textTheme.bodyMedium),
                    const SizedBox(height: 12),
                    Divider(height: 1, color: outlineColor.withValues(alpha: 0.25)),
                    const SizedBox(height: 10),
                    Row(children: [
                      Icon(Icons.text_fields_rounded, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 10), Text(s.fontWeight, style: theme.textTheme.titleMedium),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                        child: Text(['Normal', 'Medium', 'Semi-Bold', 'Bold'][settings.fontWeightIndex], style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Slider(value: settings.fontWeightIndex.toDouble(), min: 0, max: 3, divisions: 3,
                      label: ['Normal', 'Medium', 'Semi-Bold', 'Bold'][settings.fontWeightIndex],
                      onChanged: (v) => ref.read(settingsProvider.notifier).setFontWeightIndex(v.round()),
                    ),
                    const SizedBox(height: 12),
                    Divider(height: 1, color: outlineColor.withValues(alpha: 0.25)),
                    const SizedBox(height: 12),
                    Row(children: [
                      Icon(Icons.zoom_in_rounded, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 10), Text(s.defaultWebZoom, style: theme.textTheme.titleMedium),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(color: theme.colorScheme.primary.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(12)),
                        child: Text('${(_draggingWebZoom ?? settings.webZoomPercent.toDouble()).round()}%', style: TextStyle(color: theme.colorScheme.primary, fontWeight: FontWeight.w700)),
                      ),
                    ]),
                    const SizedBox(height: 8),
                    Slider(value: _draggingWebZoom ?? settings.webZoomPercent.toDouble(), min: 50, max: 200, divisions: 30,
                      label: '${(_draggingWebZoom ?? settings.webZoomPercent.toDouble()).round()}%',
                      onChanged: (v) => setState(() => _draggingWebZoom = v),
                      onChangeEnd: (v) { ref.read(settingsProvider.notifier).setWebZoom(v.round()); setState(() => _draggingWebZoom = null); },
                    ),
                    Text(s.webZoomDesc, style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white54 : const Color(0xFF6C8594))),
                  ]),
                ),
                const SizedBox(height: 12),
                SectionLabel(label: s.preferences, theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                  decoration: BoxDecoration(
                    color: cardColor, borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.startupPage, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 8),
                      Row(children: [
                        Expanded(
                          child: _StartupTabButton(
                            label: s.startupChat,
                            isSelected: settings.startupTabIndex == 0,
                            onTap: () => ref.read(settingsProvider.notifier).setStartupTabIndex(0),
                            theme: theme,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: _StartupTabButton(
                            label: s.startupKnowledge,
                            isSelected: settings.startupTabIndex == 1,
                            onTap: () => ref.read(settingsProvider.notifier).setStartupTabIndex(1),
                            theme: theme,
                          ),
                        ),
                      ]),
                      const SizedBox(height: 12),
                      Divider(height: 1, color: outlineColor.withValues(alpha: 0.25)),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(s.memorySortNewestFirst, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(s.memorySortNewestFirstDesc,
                          style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white54 : const Color(0xFF6C8594)),
                        ),
                        value: settings.memorySortNewestFirst,
                        onChanged: (v) => ref.read(settingsProvider.notifier).setMemorySortNewestFirst(v),
                      ),
                      Divider(height: 1, color: outlineColor.withValues(alpha: 0.25)),
                      const SizedBox(height: 8),
                      SwitchListTile(
                        contentPadding: EdgeInsets.zero,
                        title: Text(s.hideInboxTab, style: const TextStyle(fontWeight: FontWeight.bold)),
                        subtitle: Text(s.hideInboxTabDesc,
                          style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white54 : const Color(0xFF6C8594)),
                        ),
                        value: settings.hideInboxTab,
                        onChanged: (v) => ref.read(settingsProvider.notifier).setHideInboxTab(v),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StartupTabButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final ThemeData theme;

  const _StartupTabButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = theme.brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? theme.colorScheme.primary
              : (isDark ? Colors.white.withValues(alpha: 0.08) : Colors.black.withValues(alpha: 0.06)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              color: isSelected ? Colors.white : theme.colorScheme.onSurface,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}
