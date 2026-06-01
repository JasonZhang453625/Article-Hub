import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/passage.dart';
import '../../data/models/source_platform.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/url_helpers.dart';
import 'widgets/url_input_field.dart';
import 'widgets/tag_input.dart';

class AddArticleScreen extends ConsumerStatefulWidget {
  const AddArticleScreen({super.key});

  @override
  ConsumerState<AddArticleScreen> createState() => _AddArticleScreenState();
}

class _AddArticleScreenState extends ConsumerState<AddArticleScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();
  final _tagController = TextEditingController();

  List<String> _tags = [];
  SourcePlatform _detectedPlatform = SourcePlatform.web;

  @override
  void dispose() {
    _urlController.dispose();
    _titleController.dispose();
    _notesController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  void _onUrlChanged(String url) {
    setState(() {
      _detectedPlatform = SourcePlatform.fromUrl(url);
    });
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    final cleanedUrl = cleanUrl(_urlController.text.trim());
    final title = _titleController.text.trim().isEmpty
        ? extractDomain(cleanedUrl)
        : _titleController.text.trim();

    final article = Article(
      id: const Uuid().v4(),
      url: cleanedUrl,
      title: title,
      source: _detectedPlatform,
      tags: _tags,
      notes: _notesController.text.trim(),
    );

    await ref.read(articlesProvider.notifier).add(article);

    if (mounted) {
      Navigator.of(context).pop();
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

    final count = await ref.read(articlesProvider.notifier).addMany(urls);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('Added $count article${count == 1 ? '' : 's'}')),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final visiblePlatforms = ref.watch(visibleSourcePlatformsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Article'),
        actions: [
          IconButton(
            icon: const Icon(Icons.playlist_add_rounded),
            tooltip: 'Add multiple URLs',
            onPressed: _openBulkImport,
          ),
          TextButton(onPressed: _save, child: const Text('Save')),
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
                    const Text(
                      'Supported sources',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 8),
                    const Text(
                      'Paste links from your enabled platforms and the app will detect the source automatically.',
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
                    const SnackBar(
                      content: Text('Could not read from clipboard'),
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title (optional)',
                  hintText: 'Enter a title for this article',
                  prefixIcon: Icon(Icons.title),
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
                decoration: const InputDecoration(
                  labelText: 'Notes (optional)',
                  hintText: 'Add any notes about this article',
                  prefixIcon: Icon(Icons.notes),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: _save,
                  icon: const Icon(Icons.save_rounded),
                  label: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Save article'),
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

/// Bottom sheet for pasting multiple URLs at once. Pops with the parsed,
/// validated, de-duplicated URL list (or null if cancelled).
class _BulkImportSheet extends StatefulWidget {
  const _BulkImportSheet();

  @override
  State<_BulkImportSheet> createState() => _BulkImportSheetState();
}

class _BulkImportSheetState extends State<_BulkImportSheet> {
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
            Text('Add multiple URLs',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 4),
            Text(
              'Paste one URL per line (or separated by spaces/commas). '
              'Sources are detected automatically.',
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
                        ? 'Add'
                        : 'Add $_validCount URL${_validCount == 1 ? '' : 's'}',
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

