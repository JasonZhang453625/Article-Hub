import 'dart:convert';
import 'dart:developer' as developer;
import '../models/passage.dart';
import '../models/settings.dart';
import '../models/folder.dart';
import '../../shared/providers/article_providers.dart';
import '../../shared/providers/settings_providers.dart';
import 'ai_service.dart';
import 'content_extractor.dart';
import 'embedding_service.dart';
import 'index_service.dart';
import 'metadata_service.dart';
import 'page_loader.dart';
import 'prompt_service.dart';

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
  /// Cap text sent to tag/folder AI prompts when the body is very long.
  static const int _aiContextMaxChars = 6000;

  final ArticlesNotifier _articles;
  final AppSettings? Function() _getSettings;
  final List<Folder> Function() _getFolders;
  final MetadataService _metadata;
  final ContentExtractor _extractor;
  final EmbeddingService? _embedding;
  final IndexService? _index;
  final Future<Folder?> Function(String name)? _createFolder;
  final PromptService _prompts;

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
    PromptService? promptService,
  })  : _articles = articles,
        _getSettings = getSettings,
        _getFolders = getFolders,
        _metadata = metadata ?? MetadataService(),
        _extractor = extractor ?? ContentExtractor(),
        _embedding = embedding,
        _index = index,
        _createFolder = createFolder,
        _prompts = promptService ?? PromptService();

  /// Process a single article through all stages. Returns the final article.
  Future<Article?> process(Article article) async {
    // Refresh settings and folders from providers each run.
    _settings = _getSettings();
    _folders = List<Folder>.from(_getFolders());

    var current = article;

    final isResume = current.processingStatus == ProcessingStatus.processing;
    final hasSummary = current.summary != null && current.summary!.isNotEmpty;

    // Mark as processing (skip if already processing = resuming).
    if (!isResume) {
      current = current.copyWith(
        processingStatus: ProcessingStatus.processing,
        processingStage: ProcessingStage.metadata,
      );
      await _articles.update(current);
    }

    // Stage 1: Metadata (always redo — needs _fetchedPageCache for content)
    current = await _stageMetadata(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    // Stage 2: Content extraction (always redo — _contentCache lost on restart)
    current = await _stageContent(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    // Stage 3: AI summary — skip if already persisted (most expensive stage)
    if (!hasSummary) {
      current = await _stageSummary(current);
      if (current.processingStatus == ProcessingStatus.failed) {
        await _articles.update(current);
        return current;
      }
    } else {
      _notifyStage(current, ProcessingStage.summary);
    }

    // Stage 4: Tags (AI-generated, non-fatal on failure)
    current = await _stageTags(current);

    // Stage 5: Folder suggestion (auto-classifies to folderId, non-fatal)
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

  /// Full-text save path: metadata → extract body → store body as summary
  /// (no AI compression) → tags → folder → index.
  ///
  /// Title still comes from metadata. Tags/folder still use AI when configured.
  /// User thoughts remain in [Article.notes] and are never overwritten.
  Future<Article?> processFullText(Article article) async {
    _settings = _getSettings();
    _folders = List<Folder>.from(_getFolders());

    var current = article.copyWith(
      processingStatus: ProcessingStatus.processing,
      processingStage: ProcessingStage.metadata,
    );
    await _articles.update(current);

    current = await _stageMetadata(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    current = await _stageContent(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    // Promote extracted body to summary without AI summarization.
    _notifyStage(current, ProcessingStage.summary);
    final body = _contentCache.remove(current.id) ?? '';
    if (body.trim().isEmpty) {
      current = _fail(current, 'summary', 'Could not extract page content');
      await _articles.update(current);
      return current;
    }
    current = current.copyWith(summary: body.trim(), isFullText: true);
    await _articles.update(current);

    current = await _stageTags(current);
    current = await _stageFolderSuggestion(current);

    current = current.copyWith(
      processingStatus: ProcessingStatus.completed,
      processingStage: Article.clearValue,
      lastProcessedAt: DateTime.now(),
    );
    await _articles.update(current);

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

  /// Process a file-based article: skip metadata/content stages and inject
  /// [content] directly into the pipeline starting from the summary stage.
  Future<Article?> processFile(Article article, String content) async {
    _settings = _getSettings();
    _folders = List<Folder>.from(_getFolders());

    var current = article;

    current = current.copyWith(
      processingStatus: ProcessingStatus.processing,
      processingStage: ProcessingStage.summary,
    );
    await _articles.update(current);

    // Inject the file content directly — bypass metadata and content stages.
    _contentCache[current.id] = content;

    // Stage 3: AI summary
    current = await _stageSummary(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    // Stage 4: Tags
    current = await _stageTags(current);

    // Stage 5: Folder suggestion
    current = await _stageFolderSuggestion(current);

    current = current.copyWith(
      processingStatus: ProcessingStatus.completed,
      processingStage: Article.clearValue,
      lastProcessedAt: DateTime.now(),
    );
    await _articles.update(current);

    await _updateIndex(current);

    return current;
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
        isFullText: false,
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

      final tags = await _generateTags(
        article.title,
        _truncateForAi(summary),
      );
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
      developer.log('tag generation failed: $e', name: 'memora.pipeline');
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

    final tagSystem = await _prompts.load('tags/system.txt');
    final tagPrompt = await _prompts.load('tags/user_prompt.txt');

    final response = await ai.chat(
      systemPrompt: tagSystem,
      userMessage: '$tagPrompt\n\nTitle: $title\n\nSummary: $summary',
      temperature: 0.3,
      maxTokens: 200,
    );
    if (response == null) return [];

    // Try to extract a JSON array from the response.
    final text = response.trim();
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start == -1 || end == -1 || end <= start) return [];

    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      if (decoded is List) {
        return decoded.whereType<String>().take(5).toList();
      }
    } catch (_) {}
    return [];
  }

  /// Stage 5: Ask AI to suggest the best matching folder. Writes to
  /// [Article.folderId] directly (auto-classification).
  Future<Article> _stageFolderSuggestion(Article article) async {
    _notifyStage(article, ProcessingStage.folderSuggestion);
    final settings = _settings;
    if (settings == null ||
        settings.aiBaseUrl.trim().isEmpty ||
        settings.aiApiKey.trim().isEmpty) {
      developer.log('folder suggestion: skipped (AI not configured)',
          name: 'memora.pipeline');
      return article;
    }

    try {
      final folderNames = _folders.map((f) => f.name).toList();
      developer.log('folder suggestion: ${folderNames.length} folders available',
          name: 'memora.pipeline');

      if (folderNames.isEmpty && _createFolder == null) {
        developer.log('folder suggestion: skipped (no folders and cannot create)',
            name: 'memora.pipeline');
        return article;
      }

      final suggested = await _suggestFolder(
        article.title,
        _truncateForAi(article.summary ?? ''),
        folderNames,
      );
      developer.log('folder suggestion: AI returned "$suggested"',
          name: 'memora.pipeline');

      if (suggested == null) {
        developer.log('folder suggestion: AI returned null/none',
            name: 'memora.pipeline');
        return article;
      }

      // Match the suggested name back to a folder ID (case-insensitive).
      final match = _folders.where(
        (f) => f.name.toLowerCase() == suggested.toLowerCase(),
      ).firstOrNull;
      if (match != null) {
        developer.log('folder suggestion: matched existing folder "${match.name}"',
            name: 'memora.pipeline');
        return article.copyWith(folderId: match.id);
      }

      // No existing folder matched — create a new one if possible.
      if (_createFolder != null) {
        developer.log('folder suggestion: creating new folder "$suggested"',
            name: 'memora.pipeline');
        final newFolder = await _createFolder(suggested);
        if (newFolder != null) {
          _folders.add(newFolder);
          developer.log('folder suggestion: created and assigned folder "${newFolder.name}"',
              name: 'memora.pipeline');
          return article.copyWith(folderId: newFolder.id);
        } else {
          developer.log('folder suggestion: folder creation failed',
              name: 'memora.pipeline');
        }
      }
      return article;
    } catch (e) {
      developer.log('folder suggestion failed: $e',
          name: 'memora.pipeline');
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
        ? await _prompts.load('folder/system_no_folders.txt')
        : await _prompts.load('folder/system_with_folders.txt',
            {'folderNames': namesList});

    // Few-shot: prime the model with one example so it imitates the format
    // and stops returning "null"/"none" on weak models like gpt-4o-mini.
    final history = <Map<String, String>>[
      {
        'role': 'user',
        'content':
            'Title: Introduction to Neural Networks\n\nSummary: Explains how '
            'neural networks learn through backpropagation and gradient descent.\n\n'
            'Folder name:',
      },
      {
        'role': 'assistant',
        'content': folderNames.contains('AI') ? 'AI' : 'Machine Learning',
      },
    ];

    final userMessage =
        'Title: $title\n\nSummary: $summary\n\nFolder name:';
    final response = await ai.chat(
      systemPrompt: systemPrompt,
      userMessage: userMessage,
      history: history,
      temperature: 0.3,
      maxTokens: 500,
    );
    if (response == null) return null;
    developer.log(
      'folder suggestion: raw AI response = "$response"',
      name: 'memora.pipeline',
    );

    // Strip reasoning-model thinking tags (DeepSeek-R1 style).
    final stripped = response
        .replaceAll(RegExp(r'<think>.*?</think>', dotAll: true), '')
        .replaceAll(RegExp(r'<thinking>.*?</thinking>', dotAll: true), '')
        .trim();

    final cleaned = stripped.replaceAll(RegExp(r'''["'`.]'''), '');
    if (cleaned.isEmpty) return null;
    const placeholders = {'none', 'null', 'nil', 'n/a', 'na', 'undefined'};
    if (placeholders.contains(cleaned.toLowerCase())) return null;
    return cleaned;
  }

  // ── Helpers ────────────────────────────────────────────────────────────

  String _truncateForAi(String text) {
    if (text.length <= _aiContextMaxChars) return text;
    return text.substring(0, _aiContextMaxChars);
  }

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
          name: 'memora.pipeline',
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
        name: 'memora.pipeline',
      );
    } catch (e) {
      developer.log('index update failed: $e', name: 'memora.pipeline');
    }
  }

  void _notifyStage(Article article, ProcessingStage stage) {
    _articles.update(article.copyWith(processingStage: stage));
  }

  Article _fail(Article article, String stage, Object error) {
    final msg = '$stage: $error';
    developer.log('pipeline failed: $msg', name: 'memora.pipeline');
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
