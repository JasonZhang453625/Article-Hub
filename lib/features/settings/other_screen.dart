import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../config/routes.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/providers/pipeline_provider.dart';
import '../../shared/utils/snackbar_helpers.dart';
import '../../shared/widgets/delayed_reveal.dart';
import 'settings_widgets.dart';

class OtherScreen extends ConsumerWidget {
  const OtherScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;

    return Scaffold(
      appBar: AppBar(title: Text(s.settingsOther)),
      body: DelayedReveal(
        delayMs: 40, beginOffset: const Offset(0, 0.035),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SectionLabel(label: s.sourcePlatforms, theme: theme),
              const SizedBox(height: 8),
              NavTile(
                icon: Icons.dynamic_feed_rounded,
                title: s.reorderAndHide,
                subtitle: s.reorderDesc,
                cardColor: cardColor, outlineColor: outlineColor, isDark: isDark, theme: theme,
                onTap: () => context.push(AppRoutes.sourcePlatforms),
              ),
              const SizedBox(height: 14),
              SectionLabel(label: s.data, theme: theme),
              const SizedBox(height: 8),
              Container(
                width: double.infinity, padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardColor, borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.backupRestore, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text(s.backupDesc, style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white54 : const Color(0xFF6C8594))),
                  const SizedBox(height: 12),
                  Row(children: [
                    Expanded(child: FilledButton.icon(
                      onPressed: () => ref.read(backupServiceProvider).exportBackup().then((_) {}),
                      icon: const Icon(Icons.file_upload_outlined),
                      label: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(s.export)),
                    )),
                    const SizedBox(width: 12),
                    Expanded(child: OutlinedButton.icon(
                      onPressed: () async {
                        final backup = ref.read(backupServiceProvider);
                        final result = await backup.importBackup();
                        if (result != null) {
                          ref.invalidate(articlesProvider);
                          ref.invalidate(settingsProvider);
                          if (!context.mounted) return;
                          showAppSnackBar(
                            context,
                            message: '${s.imported} ${result.articles} ${s.nWithoutSummary}',
                          );
                        }
                      },
                      icon: const Icon(Icons.file_download_outlined),
                      label: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text(s.import)),
                    )),
                  ]),
                ]),
              ),
              const SizedBox(height: 14),
              SectionLabel(label: s.preferences, theme: theme),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                decoration: BoxDecoration(
                  color: cardColor, borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                ),
                child: SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(s.detectClipboard, style: const TextStyle(fontWeight: FontWeight.bold)),
                  subtitle: Text(s.detectClipboardDesc,
                    style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white54 : const Color(0xFF6C8594)),
                  ),
                  value: ref.watch(clipboardDetectionEnabledProvider),
                  onChanged: (v) => ref.read(settingsProvider.notifier).setClipboardDetectionEnabled(v),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
