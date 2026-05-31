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

  @override
  Widget build(BuildContext context) {
    final visiblePlatforms = ref.watch(visibleSourcePlatformsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Article'),
        actions: [TextButton(onPressed: _save, child: const Text('Save'))],
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
