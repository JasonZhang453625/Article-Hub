import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/passage.dart';
import '../models/settings.dart';
import '../models/folder.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import 'ai_service.dart';
import 'content_extractor.dart';
import 'embedding_service.dart';
import 'http_client.dart';
import 'index_service.dart';
import 'metadata_service.dart';

/// Orchestrates the sequential processing of an Article through all
/// knowledge-ification stages: metadata → content → summary → tags → folder.
///
/// Each stage updates the Article's [processingStatus] and [processingStage]
/// in Hive so the UI can reflect progress and failures are never lost.
///
/// The extracted page body is held in a transient in-memory cache
/// ([_contentCache]) keyed by article id, NEVER persisted into the
/// user-facing `notes` field. If the pipeline crashes mid-run the cache
/// is simply lost — no risk of corrupting user notes.
class ProcessingPipeline {
  final ArticlesNotifier _articles;
  final AppSettings? _settings;
  final List<Folder> _folders;
  final MetadataService _metadata;
  final ContentExtractor _extractor;
  final EmbeddingService? _embedding;
  final IndexService? _index;

  /// Per-article fetched page, scoped to a single pipeline run.
  /// Stage 1 (metadata) fetches and caches; Stage 2 (content) reuses.
  final Map<String, FetchedPage> _fetchedPageCache = <String, FetchedPage>{};

  /// Per-article extracted content, scoped to a single pipeline run.
  /// Cleared as soon as the summary stage finishes (or fails).
  final Map<String, String> _contentCache = <String, String>{};

  ProcessingPipeline({
    required ArticlesNotifier articles,
    required AppSettings? settings,
    List<Folder> folders = const [],
    MetadataService? metadata,
    ContentExtractor? extractor,
    EmbeddingService? embedding,
    IndexService? index,
  })  : _articles = articles,
        _settings = settings,
        _folders = folders,
        _metadata = metadata ?? MetadataService(),
        _extractor = extractor ?? ContentExtractor(),
        _embedding = embedding,
        _index = index;

  /// Process a single article through all stages. Returns the final article.
  Future<Article?> process(Article article) async {
    var current = article;

    // Mark as processing.
    current = current.copyWith(
      processingStatus: ProcessingStatus.processing,
      processingStage: ProcessingStage.metadata,
    );
    await _articles.update(current);

    // Stage 1: Metadata
    current = await _stageMetadata(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    // Stage 2: Content extraction
    current = await _stageContent(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    // Stage 3: AI summary
    current = await _stageSummary(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    // Stage 4: Tags (AI-generated, auto-written — non-fatal on failure)
    current = await _stageTags(current);

    // Stage 5: Folder suggestion (writes suggestedFolderId, non-fatal)
    current = await _stageFolderSuggestion(current);

    // Mark completed.
    current = current.copyWith(
      processingStatus: ProcessingStatus.completed,
      processingStage: Article.clearValue,
      lastProcessedAt: DateTime.now(),
    );
    await _articles.update(current);

    // Incrementally update the vector index.
    _updateIndex(current);

    return current;
  }

  /// Retry a failed article: bump retry count and re-run from scratch.
  Future<Article?> retry(Article article) async {
    return process(article.copyWith(
      processingStatus: ProcessingStatus.pending,
      processingError: Article.clearValue,
      retryCount: article.retryCount + 1,
    ));
  }

  // ── Stage implementations ──────────────────────────────────────────────

  Future<Article> _stageMetadata(Article article) async {
    _notifyStage(article, ProcessingStage.metadata);
    try {
      // Fetch the page once and cache it for Stage 2.
      final http = AppHttpClient();
      final page = await http.fetch(article.url);
      http.dispose();
      if (page != null) {
        _fetchedPageCache[article.id] = page;
        final meta = _metadata.fromFetchedPage(page, article.url);
        return article.copyWith(
          title: (meta.title != null && meta.title!.isNotEmpty)
              ? meta.title!
              : article.title,
          coverImageUrl: meta.imageUrl ?? article.coverImageUrl,
        );
      }
      // If fetch failed, fall back to direct fetch (may still work for some URLs).
      final meta = await _metadata.fetch(article.url);
      return article.copyWith(
        title: (meta.title != null && meta.title!.isNotEmpty)
            ? meta.title!
            : article.title,
        coverImageUrl: meta.imageUrl ?? article.coverImageUrl,
      );
    } catch (e) {
      return _fail(article, 'metadata', e);
    }
  }

  Future<Article> _stageContent(Article article) async {
    _notifyStage(article, ProcessingStage.content);
    try {
      String? content;

      // Try to reuse the page fetched in Stage 1.
      final cachedPage = _fetchedPageCache.remove(article.id);
      if (cachedPage != null) {
        content = _extractor.fromFetchedPage(cachedPage);
      }

      // Fallback to a fresh fetch if cached page wasn't available or extraction failed.
      if (content == null || content.isEmpty) {
        content = await _extractor.extract(article.url);
      }

      if (content == null || content.isEmpty) {
        return _fail(article, 'content', 'Could not extract page content');
      }
      // Hold extracted content in a transient cache; the summary stage will
      // read it. Never persist it into the user-facing `notes` field.
      _contentCache[article.id] = content;
      return article;
    } catch (e) {
      return _fail(article, 'content', e);
    }
  }

  Future<Article> _stageSummary(Article article) async {
    _notifyStage(article, ProcessingStage.summary);
    if (_settings == null ||
        _settings.aiBaseUrl.trim().isEmpty ||
        _settings.aiApiKey.trim().isEmpty) {
      _contentCache.remove(article.id);
      return _fail(article, 'summary', 'AI not configured');
    }

    final ai = AiService(
      baseUrl: _settings.aiBaseUrl,
      apiKey: _settings.aiApiKey,
      model: _settings.aiModel,
    );
    final langHint = aiLanguagePrompt(_settings.languageIndex);

    try {
      final cachedContent = _contentCache.remove(article.id);
      String? summary;

      if (cachedContent != null && cachedContent.isNotEmpty) {
        summary = await ai.summarize(article.title, cachedContent,
            languageHint: langHint);
      } else {
        summary = await ai.summarizeFromUrl(article.title, article.url,
            languageHint: langHint);
      }

      if (summary == null || summary.isEmpty) {
        return _fail(article, 'summary', 'AI returned empty summary');
      }

      return article.copyWith(summary: summary);
    } catch (e) {
      return _fail(article, 'summary', e);
    }
  }

  Future<Article> _stageTags(Article article) async {
    _notifyStage(article, ProcessingStage.tags);
    if (_settings == null ||
        _settings.aiBaseUrl.trim().isEmpty ||
        _settings.aiApiKey.trim().isEmpty) {
      return article;
    }

    try {
      final summary = article.summary ?? '';
      if (summary.isEmpty) return article;

      final tags = await _generateTags(article.title, summary);
      if (tags.isNotEmpty) {
        final existing = Set<String>.from(article.tags);
        final merged = [...article.tags];
        for (final tag in tags) {
          if (!existing.contains(tag)) merged.add(tag);
        }
        article = article.copyWith(tags: merged);
      }
      return article;
    } catch (e) {
      developer.log('tag generation failed: $e', name: 'article_hub.pipeline');
      return article;
    }
  }

  Future<List<String>> _generateTags(String title, String summary) async {
    final ai = AiService(
      baseUrl: _settings!.aiBaseUrl,
      apiKey: _settings.aiApiKey,
      model: _settings.aiModel,
    );

    final prompt =
        'You are a tagging assistant. Given a title and summary, return 2-4 '
        'short tags (single words or two-word phrases) that categorize this '
        'content. Return ONLY a JSON array of strings, nothing else. '
        'Example: ["ai", "productivity", "flutter"]';

    final response =
        await ai.summarize(title, '$summary\n\n---\n$prompt', languageHint: '');
    if (response == null) return [];

    // Try to extract a JSON array from the response.
    final text = response.trim();
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start == -1 || end == -1 || end <= start) return [];

    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      if (decoded is List) {
        return decoded.whereType<String>().take(4).toList();
      }
    } catch (_) {}
    return [];
  }

  /// Stage 5: Ask AI to suggest the best matching folder. Writes to
  /// [Article.suggestedFolderId] — the user must confirm before moving.
  Future<Article> _stageFolderSuggestion(Article article) async {
    _notifyStage(article, ProcessingStage.folderSuggestion);
    if (_folders.isEmpty) return article;
    if (_settings == null ||
        _settings.aiBaseUrl.trim().isEmpty ||
        _settings.aiApiKey.trim().isEmpty) {
      return article;
    }

    try {
      final folderNames = _folders.map((f) => f.name).toList();
      final suggested = await _suggestFolder(
        article.title,
        article.summary ?? '',
        folderNames,
      );
      if (suggested == null) return article;

      // Match the suggested name back to a folder ID (case-insensitive).
      final match = _folders.where(
        (f) => f.name.toLowerCase() == suggested.toLowerCase(),
      ).firstOrNull;
      if (match != null) {
        return article.copyWith(suggestedFolderId: match.id);
      }
      return article;
    } catch (e) {
      developer.log('folder suggestion failed: $e',
          name: 'article_hub.pipeline');
      return article;
    }
  }

  Future<String?> _suggestFolder(
      String title, String summary, List<String> folderNames) async {
    final ai = AiService(
      baseUrl: _settings!.aiBaseUrl,
      apiKey: _settings.aiApiKey,
      model: _settings.aiModel,
    );

    final namesList = folderNames.map((n) => '"$n"').join(', ');
    final prompt =
        'You are a folder organizer. Given an article title, summary, and a '
        'list of existing folders, return the single best matching folder name. '
        'If none fit well, return "none". Return ONLY the folder name or '
        '"none", nothing else. Available folders: [$namesList]';

    final response = await ai.summarize(
      title,
      '$summary\n\n---\n$prompt',
      languageHint: '',
    );
    if (response == null) return null;

    final cleaned = response.trim().replaceAll('"', '').replaceAll("'", '');
    if (cleaned.toLowerCase() == 'none' || cleaned.isEmpty) return null;
    return cleaned;
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  void _updateIndex(Article article) {
    final embedding = _embedding;
    final index = _index;
    if (embedding == null || index == null) return;
    if (article.summary == null || article.summary!.isEmpty) return;

    final input = IndexService.buildEmbeddingInput(article);
    embedding.embed(input).then((result) {
      if (result == null) return;
      index.put(IndexRecord(
        articleId: article.id,
        model: result.model,
        fingerprint: contentFingerprint(
            article.title, article.summary!, article.tags),
        vector: result.vector,
      ));
    }).catchError((e) {
      developer.log('index update failed: $e', name: 'article_hub.pipeline');
    });
  }

  void _notifyStage(Article article, ProcessingStage stage) {
    _articles.update(article.copyWith(processingStage: stage));
  }

  Article _fail(Article article, String stage, Object error) {
    final msg = '$stage: $error';
    developer.log('pipeline failed: $msg', name: 'article_hub.pipeline');
    // Drop any cached content for this article — we won't get to use it.
    _fetchedPageCache.remove(article.id);
    _contentCache.remove(article.id);
    return article.copyWith(
      processingStatus: ProcessingStatus.failed,
      processingError: msg,
      lastProcessedAt: DateTime.now(),
    );
  }

  void dispose() {
    _fetchedPageCache.clear();
    _contentCache.clear();
    _metadata.dispose();
    _extractor.dispose();
  }
}

final processingPipelineProvider = Provider<ProcessingPipeline>((ref) {
  final articles = ref.read(articlesProvider.notifier);
  final settings = ref.read(settingsProvider).valueOrNull;
  final folders = ref.read(foldersProvider).valueOrNull ?? [];
  final embedding = ref.read(embeddingServiceProvider);
  final index = ref.read(indexServiceProvider);
  return ProcessingPipeline(
    articles: articles,
    settings: settings,
    folders: folders,
    embedding: embedding,
    index: index,
  );
});
