import 'dart:async';
import 'dart:developer' as developer;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/passage.dart';
import '../../data/models/settings.dart';
import '../../data/models/source_platform.dart';
import '../../data/services/ai_service.dart';
import '../../data/services/content_extractor.dart';
import '../../data/services/embedding_service.dart';
import '../../data/services/index_service.dart';
import '../../data/services/metadata_service.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/url_helpers.dart';
import 'widgets/url_input_field.dart';
import 'widgets/tag_input.dart';

class AddArticleScreen extends ConsumerStatefulWidget {
  /// Optional URL to pre-fill (e.g. detected from the clipboard).
  final String? initialUrl;

  const AddArticleScreen({super.key, this.initialUrl});

  @override
  ConsumerState<AddArticleScreen> createState() => _AddArticleScreenState();
}

class _AddArticleScreenState extends ConsumerState<AddArticleScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();
  final _tagController = TextEditingController();
  final _metadataService = MetadataService();

  List<String> _tags = [];
  SourcePlatform _detectedPlatform = SourcePlatform.web;
  String? _fetchedCoverUrl;
  bool _fetchingMetadata = false;
  Timer? _fetchDebounce;
  String _lastFetchedUrl = '';
  String? _selectedFolderId;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialUrl;
    if (initial != null && initial.isNotEmpty) {
      _urlController.text = initial;
      _detectedPlatform = SourcePlatform.fromUrl(initial);
      _fetchMetadata(initial);
    }
  }

  @override
  void dispose() {
    _fetchDebounce?.cancel();
    _urlController.dispose();
    _titleController.dispose();
    _notesController.dispose();
    _tagController.dispose();
    _metadataService.dispose();
    super.dispose();
  }

  void _onUrlChanged(String url) {
    setState(() {
      _detectedPlatform = SourcePlatform.fromUrl(url);
    });
    _fetchDebounce?.cancel();
    final cleaned = cleanUrl(url.trim());
    if (isValidUrl(cleaned) && cleaned != _lastFetchedUrl) {
      _fetchDebounce = Timer(const Duration(milliseconds: 600), () {
        _fetchMetadata(cleaned);
      });
    }
  }

  Future<void> _fetchMetadata(String url) async {
    _lastFetchedUrl = url;
    setState(() => _fetchingMetadata = true);
    try {
      final meta = await _metadataService.fetch(url);
      if (!mounted) return;
      if (meta.title != null && _titleController.text.trim().isEmpty) {
        _titleController.text = meta.title!;
      }
      if (meta.imageUrl != null) {
        setState(() => _fetchedCoverUrl = meta.imageUrl);
      }
    } finally {
      if (mounted) setState(() => _fetchingMetadata = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final cleanedUrl = cleanUrl(_urlController.text.trim());
    final title = _titleController.text.trim().isEmpty
        ? cleanedUrl
        : _titleController.text.trim();

    final article = Article(
      id: const Uuid().v4(),
      url: cleanedUrl,
      title: title,
      source: _detectedPlatform,
      tags: _tags,
      notes: _notesController.text.trim(),
      coverImageUrl: _fetchedCoverUrl,
      folderId: _selectedFolderId,
    );

    final notifier = ref.read(articlesProvider.notifier);
    await notifier.add(article);

    // Capture provider-derived objects BEFORE popping. The StateNotifier
    // outlives this widget, but `ref` does not — touching `ref` after the
    // screen is popped throws (and was previously swallowed, silently
    // dropping the summary).
    final settings = ref.read(settingsProvider).valueOrNull;
    final embedding = ref.read(embeddingServiceProvider);
    final index = ref.read(indexServiceProvider);

    if (mounted) {
      Navigator.of(context).pop();
    }

    // Fire-and-forget: summarize in background if AI is configured.
    _summarizeInBackground(article, notifier, settings, embedding, index);
  }

  void _summarizeInBackground(
    Article article,
    ArticlesNotifier notifier,
    AppSettings? settings,
    EmbeddingService? embedding,
    IndexService index,
  ) {
    if (settings == null) return;
    if (settings.aiBaseUrl.trim().isEmpty ||
        settings.aiApiKey.trim().isEmpty) {
      developer.log(
        'skipping summary: AI not fully configured',
        name: 'article_hub.ai',
      );
      return;
    }

    final ai = AiService(
      baseUrl: settings.aiBaseUrl,
      apiKey: settings.aiApiKey,
      model: settings.aiModel,
    );
    final extractor = ContentExtractor();
    final langHint = aiLanguagePrompt(settings.languageIndex);

    () async {
      try {
        final content = await extractor.extract(article.url);
        if (content == null || content.isEmpty) {
          developer.log('content extraction failed, skipping summary', name: 'article_hub.ai');
          return;
        }

        developer.log(
          'extracted ${content.length} chars, calling AI',
          name: 'article_hub.ai',
        );
        final result = await ai.summarizeWithTitle(article.title, content, languageHint: langHint);

        if (result.summary == null || result.summary!.isEmpty) {
          developer.log('AI returned null/empty summary', name: 'article_hub.ai');
          return;
        }
        developer.log(
          'got summary (${result.summary!.length} chars), saving',
          name: 'article_hub.ai',
        );

        // Update title if AI provided a meaningful one (not just the domain).
        String? newTitle;
        if (result.title != null && result.title!.isNotEmpty) {
          final looksLikeDomain = result.title!.contains('.') &&
              !result.title!.contains(' ');
          if (!looksLikeDomain) {
            newTitle = result.title;
          }
        }

        final updated = article.copyWith(
          title: newTitle ?? article.title,
          summary: result.summary,
        );
        await notifier.update(updated);

        // Update vector index if embedding is configured.
        if (embedding == null) {
          developer.log(
            'skipping index update: embedding not configured',
            name: 'article_hub.index',
          );
        } else if (result.summary!.isEmpty) {
          developer.log(
            'skipping index update: empty summary',
            name: 'article_hub.index',
          );
        } else {
          try {
            final input = IndexService.buildEmbeddingInput(updated);
            final embedResult = await embedding.embed(input);
            if (embedResult == null) {
              developer.log(
                'embedding API returned null — index NOT updated for article ${updated.id}',
                name: 'article_hub.index',
              );
            } else {
              await index.put(IndexRecord(
                articleId: updated.id,
                model: embedResult.model,
                fingerprint: contentFingerprint(
                    updated.title, result.summary!, updated.tags),
                vector: embedResult.vector,
              ));
              developer.log(
                'index updated for article ${updated.id} '
                '(model=${embedResult.model}, vector dim=${embedResult.vector.length})',
                name: 'article_hub.index',
              );
            }
          } catch (e, st) {
            developer.log(
              'index update failed for article ${updated.id}',
              name: 'article_hub.index',
              error: e,
              stackTrace: st,
            );
          }
        }
      } catch (e, st) {
        developer.log(
          'background summarize failed',
          name: 'article_hub.ai',
          error: e,
          stackTrace: st,
        );
      } finally {
        extractor.dispose();
      }
    }();
  }

  Future<void> _openBulkImport() async {
    final urls = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _BulkImportSheet(),
    );
    if (urls == null || urls.isEmpty) return;

    final count = await ref.read(articlesProvider.notifier).addMany(urls);
    if (!mounted) return;
    final s = ref.read(stringsProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${s.addedNArticles} $count${count == 1 ? '' : ''}')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final visiblePlatforms = ref.watch(visibleSourcePlatformsProvider);
    final s = ref.watch(stringsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.addArticle),
        actions: [
          IconButton(
            icon: const Icon(Icons.playlist_add_rounded),
            tooltip: s.addMultipleUrls,
            onPressed: _openBulkImport,
          ),
          TextButton(onPressed: _save, child: Text(s.save)),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: const Color(0xFFE8F6FD),
                  borderRadius: BorderRadius.circular(24),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.supportedSources,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      s.supportedSourcesDesc,
                    ),
                    const SizedBox(height: 14),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final platform in visiblePlatforms.take(6))
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  platform.icon,
                                  size: 16,
                                  color: platform.accentColor,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  platform.displayName,
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              UrlInputField(
                controller: _urlController,
                onChanged: _onUrlChanged,
                detectedPlatform: _detectedPlatform,
                onPasteError: () {
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(
                      content: Text(s.clipboardReadError),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: s.titleOptional,
                  hintText: _fetchingMetadata
                      ? s.fetchingTitle
                      : s.enterTitle,
                  prefixIcon: const Icon(Icons.title),
                  suffixIcon: _fetchingMetadata
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : null,
                ),
              ),
              const SizedBox(height: 16),
              TagInput(
                controller: _tagController,
                tags: _tags,
                onAdd: (tag) {
                  setState(() {
                    if (!_tags.contains(tag)) {
                      _tags = [..._tags, tag];
                    }
                  });
                },
                onRemove: (tag) {
                  setState(() {
                    _tags = _tags.where((t) => t != tag).toList();
                  });
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _notesController,
                decoration: InputDecoration(
                  labelText: s.notesOptional,
                  hintText: s.addNotes,
                  prefixIcon: const Icon(Icons.notes),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 16),
              _FolderDropdown(
                selectedFolderId: _selectedFolderId,
                onChanged: (id) => setState(() => _selectedFolderId = id),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_rounded),
                  label: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(s.saveArticle),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _FolderDropdown extends ConsumerWidget {
  final String? selectedFolderId;
  final ValueChanged<String?> onChanged;

  const _FolderDropdown({required this.selectedFolderId, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final foldersAsync = ref.watch(foldersProvider);
    final s = ref.watch(stringsProvider);

    return foldersAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, e) => const SizedBox.shrink(),
      data: (folders) {
        return DropdownButtonFormField<String?>(
          initialValue: selectedFolderId,
          decoration: InputDecoration(
            labelText: s.folderOptional,
            prefixIcon: const Icon(Icons.folder_rounded),
          ),
          items: [
            DropdownMenuItem<String?>(
              value: null,
              child: Text(s.noFolder),
            ),
            for (final folder in folders)
              DropdownMenuItem<String?>(
                value: folder.id,
                child: Text(folder.name),
              ),
          ],
          onChanged: onChanged,
        );
      },
    );
  }
}

/// Bottom sheet for pasting multiple URLs at once. Pops with the parsed,
/// validated, de-duplicated URL list (or null if cancelled).
class _BulkImportSheet extends ConsumerStatefulWidget {
  const _BulkImportSheet();

  @override
  ConsumerState<_BulkImportSheet> createState() => _BulkImportSheetState();
}

class _BulkImportSheetState extends ConsumerState<_BulkImportSheet> {
  final _controller = TextEditingController();
  int _validCount = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_recount);
  }

  void _recount() {
    final count = parseUrlList(_controller.text).length;
    if (count != _validCount) {
      setState(() => _validCount = count);
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_recount);
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(context).pop(parseUrlList(_controller.text));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        decoration: BoxDecoration(
          color: Theme.of(context).scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(s.bulkImportTitle,
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              s.bulkImportDesc,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _controller,
              maxLines: 6,
              minLines: 4,
              autofocus: true,
              keyboardType: TextInputType.multiline,
              decoration: const InputDecoration(
                hintText: 'https://x.com/...\nhttps://bilibili.com/...',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _validCount == 0 ? null : _submit,
                icon: const Icon(Icons.playlist_add_check_rounded),
                label: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(
                    _validCount == 0
                        ? s.addNUrls
                        : '${s.addNUrls} $_validCount URL${_validCount == 1 ? '' : 's'}',
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

