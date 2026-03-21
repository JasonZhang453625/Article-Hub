import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../data/models/source_platform.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/widgets/delayed_reveal.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final Future<PackageInfo> _packageInfoFuture;

  @override
  void initState() {
    super.initState();
    _packageInfoFuture = PackageInfo.fromPlatform();
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (settings) {
          return DelayedReveal(
            delayMs: 40,
            beginOffset: const Offset(0, 0.035),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                // ── Appearance Section ──
                _SectionLabel(label: 'Appearance', theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Theme Mode',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 14),
                      Row(
                        children: [
                          _ThemeModeButton(
                            icon: Icons.brightness_auto_rounded,
                            label: 'System',
                            isSelected: settings.themeModeIndex == 0,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setThemeMode(0),
                            theme: theme,
                          ),
                          const SizedBox(width: 10),
                          _ThemeModeButton(
                            icon: Icons.light_mode_rounded,
                            label: 'Light',
                            isSelected: settings.themeModeIndex == 1,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setThemeMode(1),
                            theme: theme,
                          ),
                          const SizedBox(width: 10),
                          _ThemeModeButton(
                            icon: Icons.dark_mode_rounded,
                            label: 'Dark',
                            isSelected: settings.themeModeIndex == 2,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setThemeMode(2),
                            theme: theme,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // ── Font Size Section ──
                _SectionLabel(label: 'Font Size', theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.text_fields_rounded,
                              size: 20,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 10),
                          Text(
                            'Text Size',
                            style: theme.textTheme.titleMedium,
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${settings.fontSize.round()}',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Text('A',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600)),
                          Expanded(
                            child: Slider(
                              value: settings.fontSize,
                              min: 10,
                              max: 24,
                              divisions: 14,
                              label: settings.fontSize.round().toString(),
                              onChanged: (v) {
                                ref
                                    .read(settingsProvider.notifier)
                                    .setFontSize(v);
                              },
                            ),
                          ),
                          const Text('A',
                              style: TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.w600)),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Preview: The quick brown fox jumps over the lazy dog.',
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                // ── Web Zoom Section ──
                _SectionLabel(label: 'Reader', theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.zoom_in_rounded,
                              size: 20,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 10),
                          Text(
                            'Default Web Zoom',
                            style: theme.textTheme.titleMedium,
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${settings.webZoomPercent}%',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Slider(
                        value: settings.webZoomPercent.toDouble(),
                        min: 50,
                        max: 200,
                        divisions: 30,
                        label: '${settings.webZoomPercent}%',
                        onChanged: (v) {
                          ref
                              .read(settingsProvider.notifier)
                              .setWebZoom(v.round());
                        },
                      ),
                      Text(
                        'Controls the initial zoom level when opening articles in the built-in browser.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? Colors.white54
                              : const Color(0xFF6C8594),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 20),

                _SectionLabel(label: 'Source Platforms', theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(
                      color: outlineColor.withValues(alpha: 0.3),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Reorder And Hide',
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Drag to change the chip order. Turn off platforms you do not want to see in filters.',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? Colors.white54
                              : const Color(0xFF6C8594),
                        ),
                      ),
                      const SizedBox(height: 14),
                      ReorderableListView.builder(
                        shrinkWrap: true,
                        buildDefaultDragHandles: false,
                        physics: const NeverScrollableScrollPhysics(),
                        itemCount: settings.orderedSourcePlatforms.length,
                        onReorder: (oldIndex, newIndex) async {
                          final reordered = settings.orderedSourcePlatforms
                              .map((platform) => platform.name)
                              .toList();
                          if (newIndex > oldIndex) {
                            newIndex -= 1;
                          }
                          final moved = reordered.removeAt(oldIndex);
                          reordered.insert(newIndex, moved);
                          await ref
                              .read(settingsProvider.notifier)
                              .updateSourcePlatformOrder(reordered);
                        },
                        itemBuilder: (context, index) {
                          final platform = settings.orderedSourcePlatforms[index];
                          final isVisible = !settings
                              .hiddenSourcePlatformNameSet
                              .contains(platform.name);

                          return Padding(
                            key: ValueKey(platform.name),
                            padding: EdgeInsets.only(
                              bottom: index ==
                                      settings.orderedSourcePlatforms.length - 1
                                  ? 0
                                  : 10,
                            ),
                            child: _SourcePlatformSettingRow(
                              platform: platform,
                              isVisible: isVisible,
                              theme: theme,
                              onVisibilityChanged: (value) {
                                ref
                                    .read(settingsProvider.notifier)
                                    .setSourcePlatformVisibility(
                                      platform.name,
                                      value,
                                    );
                              },
                              dragHandle: ReorderableDragStartListener(
                                index: index,
                                child: Icon(
                                  Icons.drag_indicator_rounded,
                                  color: isDark
                                      ? Colors.white38
                                      : const Color(0xFF8AA1AF),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 32),

                // ── About Section ──
                FutureBuilder<PackageInfo>(
                  future: _packageInfoFuture,
                  builder: (context, snapshot) {
                    final packageInfo = snapshot.data;
                    final versionText = packageInfo == null
                        ? 'Article-Hub'
                        : _buildVersionLabel(packageInfo);

                    return Center(
                      child: Text(
                        versionText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color:
                              isDark ? Colors.white38 : const Color(0xFF98ADB8),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 24),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _buildVersionLabel(PackageInfo packageInfo) {
    final buildNumber = packageInfo.buildNumber.trim();
    final versionSuffix = buildNumber.isEmpty
        ? packageInfo.version
        : '${packageInfo.version}+$buildNumber';
    return 'Article-Hub v$versionSuffix';
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final ThemeData theme;

  const _SectionLabel({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _ThemeModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final ThemeData theme;

  const _ThemeModeButton({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 14),
            decoration: BoxDecoration(
              color: isSelected
                  ? primaryColor.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? primaryColor
                    : (isDark
                        ? Colors.white12
                        : const Color(0xFFD7E3EA)),
                width: isSelected ? 1.6 : 1.0,
              ),
            ),
            child: Column(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: isSelected
                      ? primaryColor
                      : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected
                        ? primaryColor
                        : theme.colorScheme.onSurface.withValues(alpha: 0.6),
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

class _SourcePlatformSettingRow extends StatelessWidget {
  final SourcePlatform platform;
  final bool isVisible;
  final ThemeData theme;
  final ValueChanged<bool> onVisibilityChanged;
  final Widget dragHandle;

  const _SourcePlatformSettingRow({
    required this.platform,
    required this.isVisible,
    required this.theme,
    required this.onVisibilityChanged,
    required this.dragHandle,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = theme.brightness == Brightness.dark;

    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor.withValues(
          alpha: isDark ? 0.5 : 0.9,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.22),
        ),
      ),
      child: Row(
        children: [
          const SizedBox(width: 10),
          dragHandle,
          const SizedBox(width: 8),
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: platform.accentColor.withValues(alpha: 0.14),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(
              platform.icon,
              size: 18,
              color: platform.accentColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  platform.displayName,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: isVisible
                        ? theme.colorScheme.onSurface
                        : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
                Text(
                  isVisible ? 'Visible in filters' : 'Hidden from filters',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: isDark
                        ? Colors.white54
                        : const Color(0xFF6C8594),
                  ),
                ),
              ],
            ),
          ),
          Switch(
            value: isVisible,
            onChanged: onVisibilityChanged,
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }
}
