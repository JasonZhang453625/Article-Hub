import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/passage.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/utils/date_formatter.dart';

class DetailScreen extends ConsumerStatefulWidget {
  final Passage passage;

  const DetailScreen({super.key, required this.passage});

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  late TextEditingController _titleController;
  late TextEditingController _notesController;
  late TextEditingController _tagController;
  late List<String> _tags;
  late bool _isFavorite;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.passage.title);
    _notesController = TextEditingController(text: widget.passage.notes);
    _tagController = TextEditingController();
    _tags = List.from(widget.passage.tags);
    _isFavorite = widget.passage.isFavorite;

    _titleController.addListener(_markChanged);
    _notesController.addListener(_markChanged);
  }

  void _markChanged() {
    if (!_hasChanges) {
      setState(() {
        _hasChanges = true;
      });
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _notesController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  Future<void> _saveAndPop() async {
    if (_hasChanges) {
      final updated = widget.passage.copyWith(
        title: _titleController.text.trim(),
        notes: _notesController.text.trim(),
        tags: _tags,
        isFavorite: _isFavorite,
      );
      await ref.read(passagesProvider.notifier).update(updated);
    }
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Passage'),
        content: const Text(
            'Are you sure you want to delete this passage? This action cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(
              backgroundColor: Colors.red,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      await ref.read(passagesProvider.notifier).delete(widget.passage.id);
      if (mounted) {
        Navigator.of(context).pop();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) {
          await _saveAndPop();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Passage Details'),
          actions: [
            IconButton(
              icon: Icon(
                _isFavorite ? Icons.star : Icons.star_border,
                color: _isFavorite ? Colors.amber : null,
              ),
              onPressed: () {
                setState(() {
                  _isFavorite = !_isFavorite;
                  _hasChanges = true;
                });
              },
              tooltip: _isFavorite ? 'Remove from favorites' : 'Add to favorites',
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: _confirmDelete,
              tooltip: 'Delete',
            ),
          ],
        ),
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // URL display
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[100],
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(Icons.link, size: 16, color: Colors.grey[600]),
                    const SizedBox(width: 8),
                    Expanded(
                      child: SelectableText(
                        widget.passage.url,
                        style: TextStyle(
                          fontSize: 13,
                          color: Colors.grey[700],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Platform chip
              Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.blue[50],
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Text(
                      widget.passage.source.displayName,
                      style: TextStyle(
                        color: Colors.blue[700],
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    'Added ${formatRelative(widget.passage.createdAt)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Colors.grey[500],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Title
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  prefixIcon: Icon(Icons.title),
                ),
              ),
              const SizedBox(height: 16),

              // Tags
              TextFormField(
                controller: _tagController,
                decoration: InputDecoration(
                  labelText: 'Add tag',
                  prefixIcon: const Icon(Icons.tag),
                  suffixIcon: IconButton(
                    icon: const Icon(Icons.add),
                    onPressed: () {
                      final text = _tagController.text.trim();
                      if (text.isNotEmpty && !_tags.contains(text)) {
                        setState(() {
                          _tags = [..._tags, text];
                          _hasChanges = true;
                        });
                        _tagController.clear();
                      }
                    },
                  ),
                ),
                onFieldSubmitted: (value) {
                  final text = value.trim();
                  if (text.isNotEmpty && !_tags.contains(text)) {
                    setState(() {
                      _tags = [..._tags, text];
                      _hasChanges = true;
                    });
                    _tagController.clear();
                  }
                },
              ),
              if (_tags.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 4,
                    children: _tags.map((tag) {
                      return Chip(
                        label: Text(tag),
                        deleteIcon: const Icon(Icons.close, size: 16),
                        onDeleted: () {
                          setState(() {
                            _tags = _tags.where((t) => t != tag).toList();
                            _hasChanges = true;
                          });
                        },
                      );
                    }).toList(),
                  ),
                ),
              const SizedBox(height: 16),

              // Notes
              TextFormField(
                controller: _notesController,
                decoration: const InputDecoration(
                  labelText: 'Notes',
                  prefixIcon: Icon(Icons.notes),
                ),
                maxLines: 4,
              ),
              const SizedBox(height: 24),

              // Dates
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.grey[50],
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.grey[200]!),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Created: ${formatDateTime(widget.passage.createdAt)}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Updated: ${formatDateTime(widget.passage.updatedAt)}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
