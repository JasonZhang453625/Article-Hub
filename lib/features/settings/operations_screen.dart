import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/passage.dart';
import '../../data/services/index_service.dart';
import '../../data/services/processing_pipeline.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/widgets/delayed_reveal.dart';
import 'settings_widgets.dart';

class OperationsScreen extends ConsumerStatefulWidget {
  const OperationsScreen({super.key});

  @override
  ConsumerState<OperationsScreen> createState() => _OperationsScreenState();
}

class _OperationsScreenState extends ConsumerState<OperationsScreen> {
  bool _rebuilding = false;
  String? _rebuildResult;
  String? _batchResult;
  bool _batchRunning = false;

  Future<void> _rebuildIndex() async {
    setState(() {
      _rebuilding = true;
      _rebuildResult = null;
    });
    final embedding = ref.read(embeddingServiceProvider);
    if (embedding == null) {
      if (mounted) {
        setState(() {
          _rebuilding = false;
          _rebuildResult = ref.read(stringsProvider).configureEmbeddingFirst;
        });
      }
      return;
    }
    final index = ref.read(indexServiceProvider);
    final articles = ref.read(articlesProvider).valueOrNull ?? [];
    final count = await rebuildIndex(
      articles: articles, embedding: embedding, index: index,
    );
    if (mounted) {
      setState(() {
        _rebuilding = false;
        _rebuildResult = '${ref.read(stringsProvider).indexedN} $count articles';
      });
    }
  }

  Future<void> _processBatch() async {
    final articles = ref.read(articlesProvider).valueOrNull ?? [];
    final toProcess = articles
        .where((a) => a.summary == null || a.summary!.isEmpty)
        .toList();
    if (toProcess.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(ref.read(stringsProvider).knowledgeBatchTitle),
        content: Text('${toProcess.length} ${ref.read(stringsProvider).nWithoutSummary}.\n\n'
            '${ref.read(stringsProvider).batchProcessConfirm}'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(ref.read(stringsProvider).cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('OK')),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() { _batchRunning = true; _batchResult = null; });
    final pipeline = ref.read(processingPipelineProvider);
    for (int i = 0; i < toProcess.length; i++) {
      final article = toProcess[i];
      final updated = article.copyWith(
        processingStatus: ProcessingStatus.pending,
        processingStage: null, processingError: null, retryCount: 0,
      );
      await ref.read(articlesProvider.notifier).update(updated);
      await pipeline.process(updated);
      if (mounted) setState(() => _batchResult = '${ref.read(stringsProvider).processedN} ${i + 1}/${toProcess.length}');
    }
    if (mounted) setState(() { _batchRunning = false; _batchResult = ref.read(stringsProvider).allProcessed; });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;
    final articles = ref.watch(articlesProvider).valueOrNull ?? [];
    final pendingBatchCount = articles.where((a) => a.summary == null || a.summary!.isEmpty).length;
    final countAsync = ref.watch(indexCountProvider);
    final indexedCount = countAsync.valueOrNull;
    final settings = ref.watch(settingsProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(title: Text(s.operations)),
      body: DelayedReveal(
        delayMs: 40, beginOffset: const Offset(0, 0.035),
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Summary style
              SectionLabel(label: s.summaryStyle, theme: theme),
              const SizedBox(height: 8),
              Container(
                width: double.infinity, padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardColor, borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                ),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(s.summaryStyle, style: theme.textTheme.titleMedium),
                  const SizedBox(height: 10),
                  Row(children: [
                    ThemeModeButton(icon: Icons.short_text_rounded, label: s.brief, isSelected: (settings?.summaryVerbosityIndex ?? 0) == 0, onTap: () => ref.read(settingsProvider.notifier).setSummaryVerbosity(0), theme: theme),
                    const SizedBox(width: 10),
                    ThemeModeButton(icon: Icons.notes_rounded, label: s.detailed, isSelected: (settings?.summaryVerbosityIndex ?? 0) == 1, onTap: () => ref.read(settingsProvider.notifier).setSummaryVerbosity(1), theme: theme),
                  ]),
                ]),
              ),
              const SizedBox(height: 14),
              // Batch knowledge-ify
              SectionLabel(label: s.knowledgeSectionLabel, theme: theme),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardColor, borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(children: [
                      Icon(Icons.batch_prediction_rounded, size: 20, color: theme.colorScheme.primary),
                      const SizedBox(width: 10),
                      Text(s.knowledgeBatchTitle, style: theme.textTheme.titleMedium),
                    ]),
                    const SizedBox(height: 4),
                    Text(s.knowledgeifyDesc,
                      style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white54 : const Color(0xFF6C8594)),
                    ),
                    const SizedBox(height: 12),
                    if (_batchRunning)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(children: [
                          const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
                          const SizedBox(width: 12),
                          Text(_batchResult ?? '', style: theme.textTheme.bodyMedium),
                        ]),
                      )
                    else if (_batchResult != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Row(children: [
                          Icon(Icons.check_circle_rounded, size: 18, color: theme.colorScheme.primary),
                          const SizedBox(width: 8),
                          Text(_batchResult!, style: theme.textTheme.bodyMedium),
                        ]),
                      )
                    else ...[
                      Text('$pendingBatchCount ${s.nWithoutSummary}',
                        style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white54 : const Color(0xFF6C8594)),
                      ),
                      const SizedBox(height: 8),
                      SizedBox(
                        width: double.infinity,
                        child: FilledButton.icon(
                          onPressed: pendingBatchCount == 0 || _batchRunning ? null : _processBatch,
                          icon: const Icon(Icons.auto_awesome_rounded),
                          label: Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Text(pendingBatchCount == 0 ? s.allProcessed : '${s.processAll} ($pendingBatchCount)'),
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(height: 14),

              // Index rebuild
              SectionLabel(label: s.indexManagement, theme: theme),
              const SizedBox(height: 8),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: cardColor, borderRadius: BorderRadius.circular(24),
                  border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.indexManagement, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 4),
                    Text(indexedCount != null ? '$indexedCount ${s.nArticlesIndexed}' : s.loadingIndexStatus,
                      style: theme.textTheme.bodySmall?.copyWith(color: isDark ? Colors.white54 : const Color(0xFF6C8594)),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _rebuilding ? null : _rebuildIndex,
                        icon: _rebuilding
                          ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                          : const Icon(Icons.build_rounded),
                        label: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(_rebuilding ? s.rebuilding : s.rebuildIndex),
                        ),
                      ),
                    ),
                    if (_rebuildResult != null) ...[
                      const SizedBox(height: 8),
                      Text(_rebuildResult!, style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.primary)),
                    ],
                  ],
                ),
              ),


            ],
          ),
        ),
      ),
    );
  }
}
