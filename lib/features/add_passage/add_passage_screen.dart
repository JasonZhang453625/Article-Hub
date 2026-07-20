import 'dart:async';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/passage.dart';
import '../../data/models/source_platform.dart';
import '../../data/services/metadata_service.dart';
import '../../data/services/local_file_importer.dart';
import '../../data/services/attachment_store.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/utils/url_helpers.dart';
import '../../shared/utils/file_content_utils.dart';
import '../../shared/utils/snackbar_helpers.dart';
import '../shell/share_save_sheet.dart';
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
  bool _saving = false;
  Timer? _fetchDebounce;
  String _lastFetchedUrl = '';
  String? _selectedFolderId;
  ShareSaveMode _saveMode = ShareSaveMode.aiMemory;

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
    } catch (_) {
      // Metadata fetch is best-effort; the user can still save manually.
    } finally {
      if (mounted) setState(() => _fetchingMetadata = false);
    }
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_saving) return;
    setState(() => _saving = true);

    try {
      final cleanedUrl = cleanUrl(_urlController.text.trim());
      final title = _titleController.text.trim().isEmpty
          ? cleanedUrl
          : _titleController.text.trim();
      final fullText = _saveMode == ShareSaveMode.fullText;

      final article = Article(
        id: const Uuid().v4(),
        url: cleanedUrl,
        title: title,
        source: _detectedPlatform,
        tags: _tags,
        notes: _notesController.text.trim(),
        coverImageUrl: _fetchedCoverUrl,
        folderId: _selectedFolderId,
        isFullText: fullText,
        processingStatus: ProcessingStatus.pending,
      );

      final notifier = ref.read(articlesProvider.notifier);
      await notifier.add(article);

      // Capture pipeline BEFORE popping — ref is invalid after pop.
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      showAppSnackBar(context, message: '${s.saveFailed}: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _openBulkImport() async {
    final urls = await showModalBottomSheet<List<String>>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _BulkImportSheet(),
    );
    if (urls == null || urls.isEmpty) return;

    try {
      final count = await ref.read(articlesProvider.notifier).addMany(urls);
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      showAppSnackBar(
        context,
        message: '${s.addedNArticles} $count${count == 1 ? '' : ''}',
      );
      Navigator.of(context).pop();
    } catch (e) {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      showAppSnackBar(context, message: '${s.saveFailed}: $e');
    }
  }

  Future<void> _importFile() async {
    final s = ref.read(stringsProvider);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const [
          'txt',
          'md',
          'pdf',
          'png',
          'jpg',
          'jpeg',
          'webp',
          'bmp',
          'gif',
        ],
      );
      if (result == null || result.files.isEmpty) return;
      final file = result.files.single;
      if (file.path == null) return;

      final path = file.path!;
      final lower = file.name.toLowerCase();
      final isImage =
          lower.endsWith('.png') ||
          lower.endsWith('.jpg') ||
          lower.endsWith('.jpeg') ||
          lower.endsWith('.webp') ||
          lower.endsWith('.bmp') ||
          lower.endsWith('.gif');
      final isPdf = lower.endsWith('.pdf');

      final notifier = ref.read(articlesProvider.notifier);
      final fullText = _saveMode == ShareSaveMode.fullText;

      if (isImage || isPdf) {
        if (kIsWeb) {
          if (mounted) {
            showAppSnackBar(
              context,
              message: isPdf ? s.pdfNotSupportedOnWeb : s.ocrNotSupportedOnWeb,
            );
          }
          return;
        }
        if (mounted) {
          showAppSnackBar(
            context,
            message: isPdf ? s.pdfExtracting : s.ocrRunning,
          );
        }
        final importer = LocalFileImporter();
        try {
          final prepared = await importer.prepare(
            sourcePath: path,
            notes: _notesController.text.trim(),
            folderId: _selectedFolderId,
          );
          if (prepared.content.trim().isEmpty) {
            if (mounted) {
              showAppSnackBar(
                context,
                message: isPdf ? s.pdfNoTextFound : s.ocrNoTextFound,
              );
            }
            return;
          }
          await notifier.add(prepared.article.copyWith(isFullText: fullText));
          if (mounted) {
            Navigator.of(context).pop();
          }
          // The application queue resumes the saved attachment from disk.
        } finally {
          await importer.dispose();
        }
        return;
      }

      final raw = await File(path).readAsString();
      final isMd = lower.endsWith('.md');
      final mdTitle = extractMarkdownTitle(raw);
      final title = isMd && mdTitle.isNotEmpty
          ? mdTitle
          : file.name.replaceAll(RegExp(r'\.[^.]+$'), '');
      final content = isMd ? markdownToPlainText(raw) : raw;

      if (content.trim().isEmpty) {
        if (mounted) {
          showAppSnackBar(context, message: s.fileReadError);
        }
        return;
      }

      final titleWithoutExt = title.replaceAll(RegExp(r'\.[^.]+$'), '');
      final id = const Uuid().v4();
      final localPath = await AttachmentStore().saveForArticle(
        articleId: id,
        sourcePath: path,
        preferredName: file.name,
      );
      final article = Article(
        id: id,
        url: 'file://$path',
        title: titleWithoutExt.isNotEmpty ? titleWithoutExt : file.name,
        source: SourcePlatform.local,
        notes: _notesController.text.trim(),
        folderId: _selectedFolderId,
        isFullText: fullText,
        localFilePath: localPath,
        localMimeType: isMd ? 'text/markdown' : 'text/plain',
        processingStatus: ProcessingStatus.pending,
      );

      await notifier.add(article);

      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar(context, message: '${s.fileReadError}: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.addArticle),
        actions: [
          IconButton(
            icon: const Icon(Icons.attach_file_rounded),
            tooltip: s.importFile,
            onPressed: _importFile,
          ),
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
              UrlInputField(
                controller: _urlController,
                onChanged: _onUrlChanged,
                detectedPlatform: _detectedPlatform,
                onPasteError: () {
                  if (!mounted) return;
                  showAppSnackBar(context, message: s.clipboardReadError);
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: s.titleOptional,
                  hintText: _fetchingMetadata ? s.fetchingTitle : s.enterTitle,
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
              _SaveModePicker(
                mode: _saveMode,
                onChanged: (mode) => setState(() => _saveMode = mode),
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
                  labelText: s.shareThoughtsLabel,
                  hintText: s.shareThoughtsHint,
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

class _SaveModePicker extends ConsumerWidget {
  final ShareSaveMode mode;
  final ValueChanged<ShareSaveMode> onChanged;

  const _SaveModePicker({required this.mode, required this.onChanged});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: _ModeOption(
                selected: mode == ShareSaveMode.fullText,
                icon: Icons.article_outlined,
                title: s.saveModeFullText,
                description: s.saveModeFullTextDesc,
                isDark: isDark,
                onTap: () => onChanged(ShareSaveMode.fullText),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _ModeOption(
                selected: mode == ShareSaveMode.aiMemory,
                icon: Icons.auto_awesome_rounded,
                title: s.saveModeAiMemory,
                description: s.saveModeAiMemoryDesc,
                isDark: isDark,
                onTap: () => onChanged(ShareSaveMode.aiMemory),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ModeOption extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String title;
  final String description;
  final bool isDark;
  final VoidCallback onTap;

  const _ModeOption({
    required this.selected,
    required this.icon,
    required this.title,
    required this.description,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final borderColor = selected
        ? primary
        : theme.colorScheme.outline.withValues(alpha: 0.6);
    final bg = selected
        ? primary.withValues(alpha: isDark ? 0.18 : 0.08)
        : theme.colorScheme.surface;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor, width: selected ? 1.6 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 22,
                color: selected ? primary : theme.colorScheme.onSurface,
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: selected ? primary : null,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  height: 1.3,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
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

  const _FolderDropdown({
    required this.selectedFolderId,
    required this.onChanged,
  });

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
            DropdownMenuItem<String?>(value: null, child: Text(s.noFolder)),
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
            Text(
              s.bulkImportTitle,
              style: Theme.of(context).textTheme.titleLarge,
            ),
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
