import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/passage.dart';
import '../../data/models/source_platform.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/utils/url_helpers.dart';
import 'widgets/url_input_field.dart';
import 'widgets/tag_input.dart';

class AddPassageScreen extends ConsumerStatefulWidget {
  const AddPassageScreen({super.key});

  @override
  ConsumerState<AddPassageScreen> createState() => _AddPassageScreenState();
}

class _AddPassageScreenState extends ConsumerState<AddPassageScreen> {
  final _formKey = GlobalKey<FormState>();
  final _urlController = TextEditingController();
  final _titleController = TextEditingController();
  final _notesController = TextEditingController();
  final _tagController = TextEditingController();

  List<String> _tags = [];
  SourcePlatform _detectedPlatform = SourcePlatform.generic;

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

    final passage = Passage(
      id: const Uuid().v4(),
      url: cleanedUrl,
      title: title,
      source: _detectedPlatform,
      tags: _tags,
      notes: _notesController.text.trim(),
    );

    await ref.read(passagesProvider.notifier).add(passage);

    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Add Passage'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
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
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title (optional)',
                  hintText: 'Enter a title for this passage',
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
                  hintText: 'Add any notes about this passage',
                  prefixIcon: Icon(Icons.notes),
                ),
                maxLines: 3,
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: _save,
                  child: const Padding(
                    padding: EdgeInsets.symmetric(vertical: 12),
                    child: Text('Save Passage'),
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
