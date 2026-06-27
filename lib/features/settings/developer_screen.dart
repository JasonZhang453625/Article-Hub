import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/widgets/delayed_reveal.dart';

class DeveloperScreen extends ConsumerWidget {
  const DeveloperScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;
    final logService = ref.watch(retrievalLogServiceProvider);

    return Scaffold(
      appBar: AppBar(title: Text(s.settingsDev)),
      body: DelayedReveal(
        delayMs: 40, beginOffset: const Offset(0, 0.035),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: FutureBuilder(
            future: logService.getStats(),
            builder: (context, snapshot) {
              final stats = snapshot.data;
              return Container(
                width: double.infinity, padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardColor, borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [
                    Icon(Icons.bar_chart_rounded, size: 20, color: theme.colorScheme.primary),
                    const SizedBox(width: 10),
                    Text(s.settingsDev, style: theme.textTheme.titleMedium),
                  ]),
                  const SizedBox(height: 12),
                  if (snapshot.connectionState == ConnectionState.waiting)
                    const Padding(padding: EdgeInsets.only(top: 8, bottom: 8),
                      child: SizedBox(height: 16, width: 16, child: CircularProgressIndicator(strokeWidth: 2)))
                  else ...[
                    _statRow('Total queries', '${stats?.total ?? '-'}', theme),
                    const SizedBox(height: 6),
                    _statRow('Useful 👍', '${stats?.useful ?? '-'}', theme),
                    const SizedBox(height: 6),
                    _statRow('Not useful 👎', '${stats?.notUseful ?? '-'}', theme),
                    const SizedBox(height: 6),
                    _statRow('No feedback', stats != null ? '${stats.total - stats.useful - stats.notUseful}' : '-', theme),
                  ],
                ]),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _statRow(String label, String value, ThemeData theme) {
    return Row(children: [
      Text(label, style: theme.textTheme.bodyMedium),
      const Spacer(),
      Text(value, style: theme.textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700, color: theme.colorScheme.primary)),
    ]);
  }
}
