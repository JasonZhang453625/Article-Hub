import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/source_platform.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/widgets/delayed_reveal.dart';

class SourcePlatformsScreen extends ConsumerWidget {
  const SourcePlatformsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final settingsAsync = ref.watch(settingsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Source Platforms'),
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error: $e'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => ref.invalidate(settingsProvider),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (settings) {
          return DelayedReveal(
            delayMs: 40,
            beginOffset: const Offset(0, 0.035),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
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
                      'Drag to change the chip order. Turn off platforms you '
                      'do not want to see in filters.',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? Colors.white54
                            : const Color(0xFF6C8594),
                      ),
                    ),
                    const SizedBox(height: 10),
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
                        final platform =
                            settings.orderedSourcePlatforms[index];
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
            ),
          );
        },
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
