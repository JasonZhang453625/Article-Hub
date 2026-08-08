import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/memory_document.dart';
import '../../data/models/passage.dart';
import '../../data/models/settings.dart';
import '../../shared/providers/pipeline_provider.dart';

class SummaryRegenerationResult {
  final String? title;
  final MemoryDocument? memory;
  final List<String> tags;
  final String? coverImageUrl;
  final String? error;
  final bool scheduled;

  const SummaryRegenerationResult({
    this.title,
    this.memory,
    this.tags = const [],
    this.coverImageUrl,
    this.error,
    this.scheduled = false,
  });

  String? get summary => memory?.toMarkdown();

  bool get succeeded =>
      scheduled || (memory != null && memory!.toRetrievalText().isNotEmpty);
}

typedef SummaryRegenerationRunner =
    Future<SummaryRegenerationResult> Function(
      Article article,
      AppSettings settings,
    );

typedef SaveGeneratedSummary =
    Future<void> Function(
      String articleId,
      String? title,
      MemoryDocument memory,
      List<String> tags,
      String? coverImageUrl,
    );

typedef ScheduleSummaryRegeneration = Future<void> Function(Article article);

class SummaryRegenerationController extends StateNotifier<Set<String>> {
  final SummaryRegenerationRunner? _runner;
  final SaveGeneratedSummary? _save;
  final ScheduleSummaryRegeneration? _schedule;
  final Map<String, Future<SummaryRegenerationResult>> _jobs = {};

  /// Tags produced by the latest regeneration attempt per article. Kept until
  /// the job leaves the running set so the UI can show them (and the user can
  /// keep them) even when the queue processes the re-enqueued article.
  final Map<String, List<String>> generatedTags = {};

  SummaryRegenerationController({
    SummaryRegenerationRunner? runner,
    SaveGeneratedSummary? save,
    ScheduleSummaryRegeneration? schedule,
  }) : assert(
         schedule != null || (runner != null && save != null),
         'Provide durable scheduling or a runner and save callback.',
       ),
       _runner = runner,
       _save = save,
       _schedule = schedule,
       super(const <String>{});

  Future<SummaryRegenerationResult> regenerate(
    Article article,
    AppSettings settings,
  ) {
    final existing = _jobs[article.id];
    if (existing != null) return existing;

    state = {...state, article.id};
    final job = _schedule == null
        ? _runAndSave(article, settings)
        : _scheduleAndPersist(article);
    _jobs[article.id] = job;
    job.whenComplete(() {
      _jobs.remove(article.id);
      if (mounted) {
        state = {...state}..remove(article.id);
      }
    });
    return job;
  }

  Future<SummaryRegenerationResult> _runAndSave(
    Article article,
    AppSettings settings,
  ) async {
    try {
      final result = await _runner!(article, settings);
      if (result.succeeded) {
        if (result.tags.isNotEmpty) {
          generatedTags[article.id] = result.tags;
        }
        await _save!(
          article.id,
          result.title,
          result.memory!,
          result.tags,
          result.coverImageUrl,
        );
      }
      return result;
    } catch (error) {
      return SummaryRegenerationResult(error: error.toString());
    }
  }

  Future<SummaryRegenerationResult> _scheduleAndPersist(Article article) async {
    try {
      await _schedule!(
        article.copyWith(
          summary: Article.clearValue,
          memory: Article.clearValue,
          summaryFeedback: Article.clearValue,
          isFullText: false,
          processingStatus: ProcessingStatus.pending,
          processingStage: Article.clearValue,
          processingError: Article.clearValue,
        ),
      );
      return const SummaryRegenerationResult(scheduled: true);
    } catch (error) {
      return SummaryRegenerationResult(error: error.toString());
    }
  }
}

final summaryRegenerationProvider =
    StateNotifierProvider<SummaryRegenerationController, Set<String>>((ref) {
      return SummaryRegenerationController(
        schedule: ref.read(processingQueueProvider).enqueue,
      );
    });

/// Latest AI-generated tags per article from the most recent regeneration.
/// Lives on the controller so the summary screen can display them while the
/// regenerated memory is still queued for processing.
final summaryRegenerationTagsProvider =
    Provider<Map<String, List<String>>>((ref) {
  final controller = ref.watch(summaryRegenerationProvider.notifier);
  return controller.generatedTags;
});
