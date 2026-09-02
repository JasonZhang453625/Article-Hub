import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:uuid/uuid.dart';
import '../models/memory_document.dart';
import '../models/passage.dart';
import '../models/settings.dart';
import '../models/folder.dart';
import '../../shared/providers/article_providers.dart';
import '../../shared/providers/settings_providers.dart';
import 'ai_service.dart';
import 'attachment_store.dart';
import 'content_extractor.dart';
import 'embedding_service.dart';
import 'hosted_ai_service.dart';
import 'hosted_task_run_service.dart';
import 'index_service.dart';
import 'image_understanding_service.dart';
import 'local_file_importer.dart';
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
  final AiGateway? _aiGateway;
  final ImageUnderstandingGateway? _imageUnderstanding;
  final AttachmentStore _attachments;

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
    AiGateway? aiGateway,
    ImageUnderstandingGateway? imageUnderstanding,
    AttachmentStore? attachmentStore,
  }) : _articles = articles,
       _getSettings = getSettings,
       _getFolders = getFolders,
       _metadata = metadata ?? MetadataService(),
       _extractor = extractor ?? ContentExtractor(),
       _embedding = embedding,
       _index = index,
       _createFolder = createFolder,
       _prompts = promptService ?? PromptService(),
       _aiGateway = aiGateway,
       _imageUnderstanding = imageUnderstanding,
       _attachments = attachmentStore ?? AttachmentStore();

  /// Process a single article through all stages. Returns the final article.
  Future<Article?> process(Article article) async {
    // Refresh settings and folders from providers each run.
    _settings = _getSettings();
    _folders = List<Folder>.from(_getFolders());

    var current = article;

    final isResume = current.processingStatus == ProcessingStatus.processing;
    final hasSummary = current.hasMemory;

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
      await _notifyStage(current, ProcessingStage.summary);
    }

    // Hosted summary.final returns memory only, so its dedicated tags stage is
    // the sole memory.tags call. BYOK summaries still include tags directly.
    if (current.memory?.kind == MemoryKind.aiMemory &&
        _aiGateway is! HostedAiService) {
      await _notifyStage(current, ProcessingStage.tags);
    } else {
      current = await _stageTags(current);
      if (current.processingStatus == ProcessingStatus.failed) {
        await _articles.update(current);
        return current;
      }
    }

    // Stage 5: Folder suggestion (auto-classifies to folderId, non-fatal)
    current = await _stageFolderSuggestion(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    // Mark completed.
    final completedGeneration = current.hostedTaskGeneration;
    current = current.copyWith(
      processingStatus: ProcessingStatus.completed,
      processingStage: Article.clearValue,
      lastProcessedAt: DateTime.now(),
      hostedTaskGeneration: Article.clearValue,
    );
    await _articles.update(current);
    await _finalizeHostedGeneration(current.id, completedGeneration);

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
    await _notifyStage(current, ProcessingStage.summary);
    final body = _contentCache.remove(current.id) ?? '';
    if (body.trim().isEmpty) {
      current = _fail(current, 'summary', 'Could not extract page content');
      await _articles.update(current);
      return current;
    }
    current = current.copyWith(
      summary: Article.clearValue,
      memory: MemoryDocument.fullText(
        body: body.trim(),
        format: 'plain',
        generation: MemoryGeneration(
          method: 'full_text',
          generatedAt: DateTime.now(),
        ),
      ),
      isFullText: true,
    );
    await _articles.update(current);

    // Hosted summary.final returns memory only. BYOK summaries still include
    // tags directly in their structured response.
    if (current.memory?.kind != MemoryKind.aiMemory ||
        _aiGateway is HostedAiService) {
      current = await _stageTags(current);
      if (current.processingStatus == ProcessingStatus.failed) {
        await _articles.update(current);
        return current;
      }
    }
    current = await _stageFolderSuggestion(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    final completedGeneration = current.hostedTaskGeneration;
    current = current.copyWith(
      processingStatus: ProcessingStatus.completed,
      processingStage: Article.clearValue,
      lastProcessedAt: DateTime.now(),
      hostedTaskGeneration: Article.clearValue,
    );
    await _articles.update(current);
    await _finalizeHostedGeneration(current.id, completedGeneration);

    await _updateIndex(current);
    _fetchedPageCache.remove(current.id);

    return current;
  }

  /// Continues a durable queued job after an app restart.
  ///
  /// The processing state is persisted on [Article], while fetched HTML and
  /// extracted text intentionally are not. URL jobs therefore re-fetch their
  /// source; local attachments are re-extracted from the app-owned file.
  Future<Article?> resume(Article article) async {
    if (article.isLocalImage) {
      return processImages(article);
    }
    if (article.isLocalAttachment && article.localFilePath != null) {
      return _resumeLocalAttachment(article);
    }
    return article.isFullText ? processFullText(article) : process(article);
  }

  /// Prepares a failed article for a fresh serialized queue attempt.
  ///
  /// A terminal Hosted task binding must rotate to a new generation before it
  /// is enqueued. Otherwise every UI retry only observes the same failed run.
  Future<Article> prepareRetry(Article article) async {
    var generation = article.hostedTaskGeneration;
    final ai = _aiGateway;
    if (ai is HostedAiService && generation != null) {
      try {
        final replayable = await ai.hasReplayableTaskGeneration(
          articleId: article.id,
          generation: generation,
        );
        if (!replayable) {
          await ai.finalizeTaskGeneration(
            articleId: article.id,
            generation: generation,
          );
          generation = const Uuid().v4();
        }
      } catch (_) {
        // Fail closed: if local recovery metadata cannot be inspected, retain
        // the generation so a retry cannot create a duplicate paid task.
      }
    }
    return article.copyWith(
      processingStatus: ProcessingStatus.pending,
      processingError: Article.clearValue,
      retryCount: article.retryCount + 1,
      hostedTaskGeneration: generation,
    );
  }

  /// Retry a failed article immediately outside [ProcessingQueue].
  ///
  /// UI callers should prefer `ProcessingQueue.retry` so work remains
  /// serialized with every other durable pipeline job.
  Future<Article?> retry(Article article) async {
    return resume(await prepareRetry(article));
  }

  Future<Article?> _resumeLocalAttachment(Article article) async {
    if (article.isLocalAttachment && article.localFilePath != null) {
      if (!article.isLocalPdf) {
        final failed = _fail(
          article,
          'content',
          'Local image recognition is not configured',
        );
        await _articles.update(failed);
        return failed;
      }
      try {
        final importer = LocalFileImporter();
        final text = await importer.reExtract(article);
        if (text.trim().isEmpty) {
          return _fail(
            article,
            'content',
            'No extractable text in PDF (may be a scanned document)',
          );
        }
        return processFile(article, text, fullText: article.isFullText);
      } catch (e) {
        final failed = _fail(article, 'content', e);
        await _articles.update(failed);
        return failed;
      }
    }
    return article.isFullText ? processFullText(article) : process(article);
  }

  /// Understands a durable ordered image set, persists the canonical result,
  /// then feeds its Markdown projection into the existing text pipeline.
  Future<Article?> processImages(Article article) async {
    _settings = _getSettings();
    _folders = List<Folder>.from(_getFolders());

    var current = article.copyWith(
      processingStatus: ProcessingStatus.processing,
      processingStage: ProcessingStage.imageUnderstanding,
      processingError: Article.clearValue,
    );
    await _articles.update(current);

    final images =
        current.attachments.where((attachment) => attachment.isImage).toList()
          ..sort((a, b) => a.order.compareTo(b.order));
    if (images.isEmpty) {
      final failed = _fail(
        current,
        'image_understanding',
        'This legacy image has no upload fingerprint. Add it again to process it.',
      );
      await _articles.update(failed);
      return failed;
    }

    var understanding = current.imageUnderstanding;
    final gateway = _imageUnderstanding;
    final identityMatches =
        gateway is! IdentifiedImageUnderstandingGateway ||
        (understanding?.provider == gateway.provider &&
            understanding?.model == gateway.model);
    final canReuse =
        identityMatches &&
        (understanding?.matchesAttachments(
              images,
              expectedPromptVersion: imageUnderstandingPromptVersion,
            ) ??
            false);
    if (!canReuse) {
      if (gateway == null) {
        final failed = _fail(
          current,
          'image_understanding',
          'Image understanding service is not configured',
        );
        await _articles.update(failed);
        return failed;
      }
      try {
        final uploads = <ImageUnderstandingUpload>[];
        for (final attachment in images) {
          final file = await _attachments.resolve(attachment.localPath);
          if (file == null) {
            throw StateError(
              'Local image is unavailable: ${attachment.originalFileName}',
            );
          }
          uploads.add(
            ImageUnderstandingUpload(
              attachment: attachment,
              bytes: await File(file.path).readAsBytes(),
            ),
          );
        }
        understanding = await gateway.understand(
          articleId: current.id,
          images: uploads,
          locale: _imageUnderstandingLocale(),
        );
        final suggestedTitle = understanding.suggestedTitle.trim();
        current = current.copyWith(
          title: current.title.trim().isEmpty && suggestedTitle.isNotEmpty
              ? suggestedTitle
              : current.title,
          imageUnderstanding: understanding,
        );
        // This write is the retry boundary. Later stages must reuse it.
        await _articles.update(current);
      } catch (error) {
        final failed = _fail(current, 'image_understanding', error);
        await _articles.update(failed);
        return failed;
      }
    }

    final markdown = understanding?.combinedMarkdown.trim() ?? '';
    if (markdown.isEmpty) {
      final failed = _fail(
        current,
        'image_understanding',
        'Image understanding returned no content',
      );
      await _articles.update(failed);
      return failed;
    }

    return processFile(
      current,
      markdown,
      fullText: current.isFullText,
      fullTextFormat: 'markdown',
      fullTextGeneration: current.isFullText
          ? MemoryGeneration(
              method: 'image_understanding',
              provider: understanding!.provider,
              model: understanding.model,
              promptVersion: understanding.promptVersion,
              generatedAt: understanding.generatedAt,
            )
          : null,
    );
  }

  /// Process a file-based article: skip metadata/content stages and inject
  /// [content] directly into the pipeline.
  ///
  /// When [fullText] is true, store the extracted body as the knowledge text
  /// without AI summarization (still runs tags/folder if AI is configured).
  Future<Article?> processFile(
    Article article,
    String content, {
    bool fullText = false,
    String? fullTextFormat,
    MemoryGeneration? fullTextGeneration,
  }) async {
    _settings = _getSettings();
    _folders = List<Folder>.from(_getFolders());

    var current = article;

    if (fullText) {
      current = current.copyWith(
        processingStatus: ProcessingStatus.processing,
        processingStage: ProcessingStage.summary,
        summary: Article.clearValue,
        memory: MemoryDocument.fullText(
          body: content,
          format:
              fullTextFormat ??
              (article.localMimeType == 'text/markdown' ? 'markdown' : 'plain'),
          generation:
              fullTextGeneration ??
              MemoryGeneration(
                method: 'full_text',
                generatedAt: DateTime.now(),
              ),
        ),
        isFullText: true,
      );
      await _articles.update(current);
    } else {
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
    }

    // Hosted summary.final returns memory only. BYOK summaries still include
    // tags directly in their structured response.
    if (current.memory?.kind != MemoryKind.aiMemory ||
        _aiGateway is HostedAiService) {
      current = await _stageTags(current);
      if (current.processingStatus == ProcessingStatus.failed) {
        await _articles.update(current);
        return current;
      }
    }

    // Stage 5: Folder suggestion
    current = await _stageFolderSuggestion(current);
    if (current.processingStatus == ProcessingStatus.failed) {
      await _articles.update(current);
      return current;
    }

    final completedGeneration = current.hostedTaskGeneration;
    current = current.copyWith(
      processingStatus: ProcessingStatus.completed,
      processingStage: Article.clearValue,
      lastProcessedAt: DateTime.now(),
      hostedTaskGeneration: Article.clearValue,
    );
    await _articles.update(current);
    await _finalizeHostedGeneration(current.id, completedGeneration);

    await _updateIndex(current);

    return current;
  }

  // ── Stage implementations ──────────────────────────────────────────────

  Future<Article> _stageMetadata(Article article) async {
    await _notifyStage(article, ProcessingStage.metadata);
    try {
      final page = await _metadata.fetchPage(article.url);
      if (page == null) {
        return _fail(article, 'metadata', 'Could not load original page');
      }

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
    await _notifyStage(article, ProcessingStage.content);
    try {
      final page = _fetchedPageCache.remove(article.id);
      final content = page == null
          ? null
          : await _extractor.extractFromFetchedPage(page);

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
    await _notifyStage(article, ProcessingStage.summary);
    final settings = _settings;
    final ai = _aiGateway;
    if (settings == null || ai == null || !ai.isConfigured) {
      _contentCache.remove(article.id);
      return _fail(article, 'summary', 'AI not configured');
    }

    final langHint = aiLanguagePrompt(settings.languageIndex);
    final taskLanguage = hostedTaskSummaryLanguageForIndex(
      settings.languageIndex,
    );

    try {
      final cachedContent = _contentCache.remove(article.id);
      if (cachedContent == null || cachedContent.isEmpty) {
        return _fail(
          article,
          'summary',
          'Could not extract page content for summarization',
        );
      }

      late final AiSummaryResult result;
      if (ai is HostedAiService) {
        final operation = await _hostedOperation(
          article: article,
          stage: 'summary',
          model: ai.model,
          language: taskLanguage.wireName,
        );
        result = await ai.summarizeWithTitleTask(
          article.title,
          cachedContent,
          language: taskLanguage,
          operationKey: operation.key,
          operation: operation.context,
        );
      } else {
        result = await ai.summarizeWithTitle(
          article.title,
          cachedContent,
          languageHint: langHint,
        );
      }

      if (result.memory == null || result.memory!.toRetrievalText().isEmpty) {
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

      final isHosted = ai is HostedAiService;
      final generatedMemory = result.memory!.withGeneration(
        MemoryGeneration(
          method: 'llm',
          provider: isHosted
              ? 'memora-hosted'
              : _providerLabel(settings.aiBaseUrl),
          model: isHosted ? ai.model : settings.aiModel,
          promptVersion: isHosted ? 'pi-summary-v1' : 'full_summary_v1',
          generatedAt: DateTime.now(),
        ),
      );
      return article.copyWith(
        title: newTitle ?? article.title,
        // Hosted summary.final contains memory only; preserve the current set
        // for the dedicated tags stage to merge. BYOK keeps its legacy
        // structured summary-and-tags response.
        tags: isHosted ? article.tags : result.tags,
        summary: Article.clearValue,
        memory: generatedMemory,
        isFullText: false,
      );
    } catch (e) {
      return _fail(article, 'summary', e);
    }
  }

  Future<Article> _stageTags(Article article) async {
    await _notifyStage(article, ProcessingStage.tags);
    final settings = _settings;
    final ai = _aiGateway;
    if (settings == null || ai == null || !ai.isConfigured) {
      return article;
    }

    try {
      final summary = article.retrievalText;
      if (summary.isEmpty) return article;

      final tags = await _generateTags(article, _truncateForAi(summary));
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
      if (e is HostedTaskRunException) {
        return _fail(article, 'tags', e);
      }
      developer.log('tag generation failed: $e', name: 'memora.pipeline');
      return article;
    }
  }

  Future<List<String>> _generateTags(Article article, String summary) async {
    final ai = _aiGateway!;
    final settings = _settings;
    if (ai is HostedAiService && settings != null) {
      final language = hostedTaskSummaryLanguageForIndex(
        settings.languageIndex,
      );
      final operation = await _hostedOperation(
        article: article,
        stage: 'tags',
        model: ai.model,
        language: language.wireName,
      );
      return ai.generateTagsTask(
        title: article.title,
        summary: summary,
        content: summary,
        existingTags: article.tags,
        language: language,
        operationKey: operation.key,
        operation: operation.context,
      );
    }

    final tagSystem = await _prompts.load('tags/system.txt');
    final tagPrompt = await _prompts.load('tags/user_prompt.txt');

    final response = await ai.chat(
      systemPrompt: tagSystem,
      userMessage: '$tagPrompt\n\nTitle: ${article.title}\n\nSummary: $summary',
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

  /// Stage 5: Ask AI to suggest the best matching folder. Protocol-v4 hosted
  /// tasks write [Article.suggestedFolderId] for user confirmation; the BYOK
  /// legacy path retains its existing direct-classification behavior.
  Future<Article> _stageFolderSuggestion(Article article) async {
    await _notifyStage(article, ProcessingStage.folderSuggestion);
    final settings = _settings;
    final ai = _aiGateway;
    if (settings == null || ai == null || !ai.isConfigured) {
      developer.log(
        'folder suggestion: skipped (AI not configured)',
        name: 'memora.pipeline',
      );
      return article;
    }

    try {
      if (ai is HostedAiService) {
        final language = hostedTaskSummaryLanguageForIndex(
          settings.languageIndex,
        );
        final operation = await _hostedOperation(
          article: article,
          stage: 'folder',
          model: ai.model,
          language: language.wireName,
        );
        final selectedId = await ai.suggestFolderTask(
          title: article.title,
          summary: _truncateForAi(article.retrievalText),
          tags: article.tags,
          folders: _folders
              .map(
                (folder) =>
                    HostedTaskFolderCandidate(id: folder.id, name: folder.name),
              )
              .toList(growable: false),
          language: language,
          operationKey: operation.key,
          operation: operation.context,
        );
        if (selectedId == null) {
          return article.copyWith(suggestedFolderId: Article.clearValue);
        }
        final selected = _folders.where((folder) => folder.id == selectedId);
        if (selected.isEmpty) {
          developer.log(
            'folder suggestion: hosted task returned an unknown folder id',
            name: 'memora.pipeline',
          );
          return article;
        }
        return article.copyWith(suggestedFolderId: selected.first.id);
      }

      final folderNames = _folders.map((f) => f.name).toList();
      developer.log(
        'folder suggestion: ${folderNames.length} folders available',
        name: 'memora.pipeline',
      );

      if (folderNames.isEmpty && _createFolder == null) {
        developer.log(
          'folder suggestion: skipped (no folders and cannot create)',
          name: 'memora.pipeline',
        );
        return article;
      }

      final suggested = await _suggestFolder(
        article.title,
        _truncateForAi(article.retrievalText),
        folderNames,
      );
      developer.log(
        'folder suggestion: AI returned "$suggested"',
        name: 'memora.pipeline',
      );

      if (suggested == null) {
        developer.log(
          'folder suggestion: AI returned null/none',
          name: 'memora.pipeline',
        );
        return article;
      }

      // Match the suggested name back to a folder ID (case-insensitive).
      final match = _folders
          .where((f) => f.name.toLowerCase() == suggested.toLowerCase())
          .firstOrNull;
      if (match != null) {
        developer.log(
          'folder suggestion: matched existing folder "${match.name}"',
          name: 'memora.pipeline',
        );
        return article.copyWith(folderId: match.id);
      }

      // No existing folder matched — create a new one if possible.
      if (_createFolder != null) {
        developer.log(
          'folder suggestion: creating new folder "$suggested"',
          name: 'memora.pipeline',
        );
        final newFolder = await _createFolder(suggested);
        if (newFolder != null) {
          _folders.add(newFolder);
          developer.log(
            'folder suggestion: created and assigned folder "${newFolder.name}"',
            name: 'memora.pipeline',
          );
          return article.copyWith(folderId: newFolder.id);
        } else {
          developer.log(
            'folder suggestion: folder creation failed',
            name: 'memora.pipeline',
          );
        }
      }
      return article;
    } catch (e) {
      if (e is HostedTaskRunException && e.retryable) {
        return _fail(article, 'folder', e);
      }
      developer.log('folder suggestion failed: $e', name: 'memora.pipeline');
      return article;
    }
  }

  Future<String?> _suggestFolder(
    String title,
    String summary,
    List<String> folderNames,
  ) async {
    final ai = _aiGateway!;

    final systemPrompt = folderNames.isEmpty
        ? await _prompts.load('folder/system_no_folders.txt')
        : await _prompts.load('folder/system_with_folders.txt');

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

    final userMessage = jsonEncode({
      'title': title,
      'summary': summary,
      'available_folders': folderNames,
    });
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

  Future<({String key, HostedTaskOperationContext context})> _hostedOperation({
    required Article article,
    required String stage,
    required String model,
    required String language,
  }) async {
    var generation = article.hostedTaskGeneration?.trim();
    if (generation == null || generation.isEmpty) {
      generation = const Uuid().v4();
      article.hostedTaskGeneration = generation;
      // This write is the logical task boundary. It must commit before a POST
      // so process-death recovery derives the same operation key.
      await _articles.update(article);
    }
    final key = await buildHostedTaskOperationKey(
      articleId: article.id,
      stage: stage,
      generation: generation,
      model: model,
      language: language,
    );
    return (
      key: key,
      context: HostedTaskOperationContext(
        articleId: article.id,
        generation: generation,
        stage: stage,
      ),
    );
  }

  Future<void> _finalizeHostedGeneration(
    String articleId,
    String? generation,
  ) async {
    final ai = _aiGateway;
    if (ai is! HostedAiService || generation == null) return;
    try {
      // Article generation was already cleared and persisted. A cleanup
      // failure can leave only harmless orphan metadata, never a duplicate run.
      await ai.finalizeTaskGeneration(
        articleId: articleId,
        generation: generation,
      );
    } catch (error) {
      developer.log(
        'hosted task generation cleanup failed: $error',
        name: 'memora.pipeline',
      );
    }
  }

  Future<void> _updateIndex(Article article) async {
    final embedding = _embedding;
    final index = _index;
    if (embedding == null || index == null) return;
    if (!article.hasMemory) return;

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
      await index.put(
        IndexRecord(
          articleId: article.id,
          model: result.model,
          fingerprint: contentFingerprint(
            article.title,
            article.retrievalText,
            article.tags,
          ),
          vector: result.vector,
        ),
      );
      developer.log(
        'index updated for article ${article.id}',
        name: 'memora.pipeline',
      );
    } catch (e) {
      developer.log('index update failed: $e', name: 'memora.pipeline');
    }
  }

  Future<void> _notifyStage(Article article, ProcessingStage stage) {
    return _articles.update(article.copyWith(processingStage: stage));
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

  String _providerLabel(String baseUrl) {
    final host = Uri.tryParse(baseUrl)?.host.trim();
    return host == null || host.isEmpty ? 'openai-compatible' : host;
  }

  String _imageUnderstandingLocale() {
    return _settings?.languageIndex == 2 ? 'en-US' : 'zh-CN';
  }

  void dispose() {
    _fetchedPageCache.clear();
    _contentCache.clear();
    _metadata.dispose();
    _extractor.dispose();
  }
}
