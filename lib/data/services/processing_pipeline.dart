import 'dart:convert';
import 'dart:developer' as developer;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../models/passage.dart';
import '../models/settings.dart';
import '../models/folder.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/providers/page_loader_provider.dart';
import 'ai_service.dart';
import 'content_extractor.dart';
import 'embedding_service.dart';
import 'index_service.dart';
import 'metadata_service.dart';
import 'page_loader.dart';

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
///
/// **WebView Fallback:**
/// MetadataService and ContentExtractor now use a ResilientPageLoader that
/// automatically tries HTTP first, then falls back to headless WebView on
/// 403/timeout/network errors. This happens transparently without user
/// intervention.
class ProcessingPipeline {
  final ArticlesNotifier _articles;
  final AppSettings? Function() _getSettings;
  final List<Folder> Function() _getFolders;
  final MetadataService _metadata;
  final ContentExtractor _extractor;
  final EmbeddingService? _embedding;
  final IndexService? _index;
  final Future<Folder?> Function(String name)? _createFolder;

  /// Mutable — refreshed from getters at the start of each [process] call.
  AppSettings? _settings;
  List<Folder> _folders = [];

  /// Per-article fetched page, scoped to a single pipeline run.
  /// Stage 1 fetches once; Stage 2 parses the same final HTML.
  final Map<String, FetchedPage> _fetchedPageCache = <String, FetchedPage>{};

  /// Per-article extracted content, scoped to a single pipeline run.
  /// Cleared as soon as the summary stage finishes (or fails).
  final Map<String, String> _contentCache = <String, String>{};

  ProcessingPipeline({
    required ArticlesNotifier articles,
    required AppSettings? Function() getSettings,
    required List<Folder> Function() getFolders,
    MetadataService? metadata,
    ContentExtractor? extractor,
    EmbeddingService? embedding,
    IndexService? index,
    Future<Folder?> Function(String name)? createFolder,
  })  : _articles = articles,
        _getSettings = getSettings,
        _getFolders = getFolders,
        _metadata = metadata ?? MetadataService(),
        _extractor = extractor ?? ContentExtractor(),
        _embedding = embedding,
        _index = index,
        _createFolder = createFolder;

  /// Process a single article through all stages. Returns the final article.
  Future<Article?> process(Article article) async {
    // Refresh settings and folders from providers each run.
    _settings = _getSettings();
    _folders = List<Folder>.from(_getFolders());

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
    await _updateIndex(current);
    _fetchedPageCache.remove(current.id);

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
      final page = await _metadata.fetchPage(article.url);
      if (page == null) return article;

      _fetchedPageCache[article.id] = page;
      final meta = _metadata.fromFetchedPage(page);
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
      final page = _fetchedPageCache.remove(article.id);
      final content =
          page == null ? null : _extractor.fromFetchedPage(page);

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
    final settings = _settings;
    if (settings == null ||
        settings.aiBaseUrl.trim().isEmpty ||
        settings.aiApiKey.trim().isEmpty) {
      _contentCache.remove(article.id);
      return _fail(article, 'summary', 'AI not configured');
    }

    final ai = AiService(
      baseUrl: settings.aiBaseUrl,
      apiKey: settings.aiApiKey,
      model: settings.aiModel,
    );
    final langHint = aiLanguagePrompt(settings.languageIndex);
    final verbosity = settings.summaryVerbosityIndex;

    try {
      final cachedContent = _contentCache.remove(article.id);
      if (cachedContent == null || cachedContent.isEmpty) {
        return _fail(
          article,
          'summary',
          'Could not extract page content for summarization',
        );
      }

      final result = await ai.summarizeWithTitle(
        article.title,
        cachedContent,
        languageHint: langHint,
        verbosity: verbosity,
      );

      if (result.summary == null || result.summary!.isEmpty) {
        return _fail(
          article,
          'summary',
          ai.lastError ?? 'AI returned empty summary',
        );
      }

      // Update title if AI provided a meaningful one (not just the domain).
      String? newTitle;
      if (result.title != null && result.title!.isNotEmpty) {
        final looksLikeDomain =
            result.title!.contains('.') && !result.title!.contains(' ');
        if (!looksLikeDomain) {
          newTitle = result.title;
        }
      }

      return article.copyWith(
        title: newTitle ?? article.title,
        summary: result.summary,
      );
    } catch (e) {
      return _fail(article, 'summary', e);
    }
  }

  Future<Article> _stageTags(Article article) async {
    _notifyStage(article, ProcessingStage.tags);
    final settings = _settings;
    if (settings == null ||
        settings.aiBaseUrl.trim().isEmpty ||
        settings.aiApiKey.trim().isEmpty) {
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
    final settings = _settings!;
    final ai = AiService(
      baseUrl: settings.aiBaseUrl,
      apiKey: settings.aiApiKey,
      model: settings.aiModel,
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
    final settings = _settings;
    if (settings == null ||
        settings.aiBaseUrl.trim().isEmpty ||
        settings.aiApiKey.trim().isEmpty) {
      return article;
    }

    try {
      final folderNames = _folders.map((f) => f.name).toList();
      developer.log('folder suggestion: ${folderNames.length} folders available',
          name: 'article_hub.pipeline');

      final suggested = await _suggestFolder(
        article.title,
        article.summary ?? '',
        folderNames,
      );
      developer.log('folder suggestion: AI returned "$suggested"',
          name: 'article_hub.pipeline');

      if (suggested == null) return article;

      // Match the suggested name back to a folder ID (case-insensitive).
      final match = _folders.where(
        (f) => f.name.toLowerCase() == suggested.toLowerCase(),
      ).firstOrNull;
      if (match != null) {
        return article.copyWith(suggestedFolderId: match.id);
      }

      // No existing folder matched — create a new one if possible.
      if (_createFolder != null) {
        developer.log('folder suggestion: creating new folder "$suggested"',
            name: 'article_hub.pipeline');
        final newFolder = await _createFolder(suggested);
        if (newFolder != null) {
          _folders.add(newFolder);
          return article.copyWith(suggestedFolderId: newFolder.id);
        }
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
    final settings = _settings!;
    final ai = AiService(
      baseUrl: settings.aiBaseUrl,
      apiKey: settings.aiApiKey,
      model: settings.aiModel,
    );

    final namesList = folderNames.map((n) => '"$n"').join(', ');
    final systemPrompt = folderNames.isEmpty
        ? 'You are a folder organizer. Given an article title and summary, '
            'suggest a concise folder name (2-4 words) to categorize this article. '
            'Return ONLY the folder name, nothing else.'
        : 'You are a folder organizer. Given an article title, summary, and a '
            'list of existing folders, return the single best matching folder name. '
            'If none fit well, suggest a new concise folder name (2-4 words). '
            'Return ONLY the folder name, nothing else. '
            'Available folders: [$namesList]';

    final userMessage = 'Title: $title\n\nSummary: $summary';
    final response = await ai.chat(
      systemPrompt: systemPrompt,
      userMessage: userMessage,
      temperature: 0.1,
      maxTokens: 50,
    );
    if (response == null) return null;

    final cleaned = response.trim().replaceAll('"', '').replaceAll("'", '');
    if (cleaned.toLowerCase() == 'none' || cleaned.isEmpty) return null;
    return cleaned;
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  Future<void> _updateIndex(Article article) async {
    final embedding = _embedding;
    final index = _index;
    if (embedding == null || index == null) return;
    if (article.summary == null || article.summary!.isEmpty) return;

    try {
      final input = IndexService.buildEmbeddingInput(article);
      final result = await embedding.embed(input);
      if (result == null) {
        developer.log(
          'embedding returned null, skipping index put for ${article.id}',
          name: 'article_hub.pipeline',
        );
        return;
      }
      await index.put(IndexRecord(
        articleId: article.id,
        model: result.model,
        fingerprint:
            contentFingerprint(article.title, article.summary!, article.tags),
        vector: result.vector,
      ));
      developer.log(
        'index updated for article ${article.id}',
        name: 'article_hub.pipeline',
      );
    } catch (e) {
      developer.log('index update failed: $e', name: 'article_hub.pipeline');
    }
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
  final embedding = ref.read(embeddingServiceProvider);
  final index = ref.read(indexServiceProvider);

  // Use the shared resilient PageLoader (HTTP → WebView fallback)
  final pageLoader = ref.read(pageLoaderProvider);

  final pipeline = ProcessingPipeline(
    articles: articles,
    getSettings: () => ref.read(settingsProvider).valueOrNull,
    getFolders: () => ref.read(foldersProvider).valueOrNull ?? [],
    metadata: MetadataService(loader: pageLoader, ownsLoader: false),
    extractor: ContentExtractor(loader: pageLoader, ownsLoader: false),
    embedding: embedding,
    index: index,
    createFolder: (name) async {
      final folder = Folder(
        id: const Uuid().v4(),
        name: name,
      );
      await ref.read(foldersProvider.notifier).add(folder);
      return folder;
    },
  );
  ref.onDispose(pipeline.dispose);
  return pipeline;
});
