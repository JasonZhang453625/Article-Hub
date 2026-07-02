import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/passage.dart';
import '../../data/models/settings.dart';
import '../../data/services/ai_service.dart';
import '../../data/services/content_extractor.dart';
import '../../data/services/metadata_service.dart';
import '../../shared/providers/page_loader_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';

class SummaryRegenerationResult {
  final String? title;
  final String? summary;
  final String? coverImageUrl;
  final String? error;

  const SummaryRegenerationResult({this.title, this.summary, this.coverImageUrl, this.error});

  bool get succeeded => summary != null && summary!.isNotEmpty;
}

typedef SummaryRegenerationRunner =
    Future<SummaryRegenerationResult> Function(
      Article article,
      AppSettings settings,
    );

typedef SaveGeneratedSummary =
    Future<void> Function(String articleId, String? title, String summary, String? coverImageUrl);

class SummaryRegenerationController extends StateNotifier<Set<String>> {
  final SummaryRegenerationRunner _runner;
  final SaveGeneratedSummary _save;
  final Map<String, Future<SummaryRegenerationResult>> _jobs = {};

  SummaryRegenerationController({
    required SummaryRegenerationRunner runner,
    required SaveGeneratedSummary save,
  }) : _runner = runner,
       _save = save,
       super(const <String>{});

  Future<SummaryRegenerationResult> regenerate(
    Article article,
    AppSettings settings,
  ) {
    final existing = _jobs[article.id];
    if (existing != null) return existing;

    state = {...state, article.id};
    final job = _runAndSave(article, settings);
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
      developer.log(
        'background summary started, articleId: ${article.id}',
        name: 'memora.ai',
      );
      final result = await _runner(article, settings);
      if (result.succeeded) {
        await _save(article.id, result.title, result.summary!, result.coverImageUrl);
        developer.log(
          'background summary saved, articleId: ${article.id}',
          name: 'memora.ai',
        );
      }
      return result;
    } catch (error, stackTrace) {
      developer.log(
        'background summary save failed',
        name: 'memora.ai',
        error: error,
        stackTrace: stackTrace,
      );
      return SummaryRegenerationResult(error: error.toString());
    }
  }
}

final summaryRegenerationProvider =
    StateNotifierProvider<SummaryRegenerationController, Set<String>>((ref) {
      final articles = ref.read(articlesProvider.notifier);
      final pageLoader = ref.read(pageLoaderProvider);

      return SummaryRegenerationController(
        runner: (article, settings) async {
          final metadataService = MetadataService(
            loader: pageLoader,
            ownsLoader: false,
          );
          final extractor = ContentExtractor(
            loader: pageLoader,
            ownsLoader: false,
          );
          final ai = AiService(
            baseUrl: settings.aiBaseUrl,
            apiKey: settings.aiApiKey,
            model: settings.aiModel,
          );
          ai.onTokensUsed = (tokens) =>
              ref.read(settingsProvider.notifier).addTokenUsage(tokens);

          try {
            // Fetch page once, reuse for both metadata and content extraction.
            final page = await metadataService.fetchPage(article.url);
            if (page == null) {
              return const SummaryRegenerationResult(
                error: 'Could not fetch page',
              );
            }

            final meta = metadataService.fromFetchedPage(page);
            final content = extractor.fromFetchedPage(page);
            if (content == null || content.isEmpty) {
              return const SummaryRegenerationResult(
                error: 'Could not extract page content',
              );
            }

            final result = await ai.summarizeWithTitle(
              article.title,
              content,
              languageHint: aiLanguagePrompt(settings.languageIndex),
              verbosity: settings.summaryVerbosityIndex,
            );
            final summary = result.summary;
            if (summary == null || summary.isEmpty) {
              return SummaryRegenerationResult(
                error: ai.lastError ?? 'AI returned an empty summary',
              );
            }

            String? newTitle;
            final generatedTitle = result.title;
            if (generatedTitle != null && generatedTitle.isNotEmpty) {
              final looksLikeDomain =
                  generatedTitle.contains('.') && !generatedTitle.contains(' ');
              if (!looksLikeDomain) newTitle = generatedTitle;
            }

            return SummaryRegenerationResult(
              title: newTitle,
              summary: summary,
              coverImageUrl: meta.imageUrl,
            );
          } catch (error, stackTrace) {
            developer.log(
              'background summary regeneration failed',
              name: 'memora.ai',
              error: error,
              stackTrace: stackTrace,
            );
            return SummaryRegenerationResult(error: error.toString());
          } finally {
            extractor.dispose();
            metadataService.dispose();
          }
        },
        save: articles.updateGeneratedSummary,
      );
    });
