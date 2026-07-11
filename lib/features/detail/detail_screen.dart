import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/models/passage.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/utils/date_formatter.dart';
import '../../shared/utils/snackbar_helpers.dart';

class DetailScreen extends ConsumerStatefulWidget {
  final Article article;

  const DetailScreen({super.key, required this.article});

  @override
  ConsumerState<DetailScreen> createState() => _DetailScreenState();
}

class _DetailScreenState extends ConsumerState<DetailScreen> {
  late TextEditingController _titleController;
  late TextEditingController _notesController;
  late TextEditingController _tagController;
  late List<String> _tags;
  late bool _isFavorite;
  late String? _selectedFolderId;
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.article.title);
    _notesController = TextEditingController(text: widget.article.notes);
    _tagController = TextEditingController();
    _tags = List.from(widget.article.tags);
    _isFavorite = widget.article.isFavorite;
    _selectedFolderId = widget.article.folderId;

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
    FocusScope.of(context).unfocus();
    if (!_hasChanges) {
      if (mounted) Navigator.of(context).pop();
      return;
    }
    try {
      final updated = widget.article.copyWith(
        title: _titleController.text.trim(),
        notes: _notesController.text.trim(),
        tags: _tags,
        isFavorite: _isFavorite,
        folderId: _selectedFolderId,
      );
      await ref.read(articlesProvider.notifier).update(updated);
      if (mounted) {
        Navigator.of(context).pop();
      }
    } catch (e) {
      if (!mounted) return;
      final s = ref.read(stringsProvider);
      showAppSnackBar(context, message: '${s.saveFailed}: $e');
    }
  }

  Future<void> _handleBack() async {
    if (!mounted) return;
    await _saveAndPop();
  }

  Future<void> _confirmDelete() async {
    final s = ref.read(stringsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.deleteArticle),
        content: Text(s.deleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            child: Text(s.delete),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      try {
        await ref.read(articlesProvider.notifier).delete(widget.article.id);
        if (mounted) {
          Navigator.of(context).pop();
        }
      } catch (e) {
        if (!mounted) return;
        showAppSnackBar(context, message: '${s.saveFailed}: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final s = ref.watch(stringsProvider);
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (!didPop) {
          await _handleBack();
        }
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.arrow_back_rounded),
            onPressed: _handleBack,
            tooltip: s.back,
          ),
          title: Text(s.articleDetails),
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
              tooltip: _isFavorite
                  ? s.removeFromFavorites
                  : s.addToFavorites,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline, color: Colors.red),
              onPressed: _confirmDelete,
              tooltip: s.delete,
            ),
          ],
        ),
        body: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 720),
            child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: widget.article.source.accentColor.withValues(
                    alpha: 0.08,
                  ),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          widget.article.source.icon,
                          size: 18,
                          color: widget.article.source.accentColor,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          widget.article.source.displayName,
                          style: TextStyle(
                            color: widget.article.source.accentColor,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const Spacer(),
                        Text(
                          '${s.addedRelative} ${formatRelative(widget.article.createdAt)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      widget.article.url,
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 13),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              TextFormField(
                controller: _titleController,
                decoration: InputDecoration(
                  labelText: s.title,
                  prefixIcon: const Icon(Icons.title),
                ),
              ),
              const SizedBox(height: 16),

              TextFormField(
                controller: _tagController,
                decoration: InputDecoration(
                  labelText: s.addTag,
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

              TextFormField(
                controller: _notesController,
                decoration: InputDecoration(
                  labelText: s.notes,
                  prefixIcon: Icon(Icons.notes),
                ),
                maxLines: 4,
              ),
              const SizedBox(height: 16),

              _FolderDropdown(
                selectedFolderId: _selectedFolderId,
                onChanged: (id) {
                  setState(() {
                    _selectedFolderId = id;
                    _hasChanges = true;
                  });
                },
              ),
              const SizedBox(height: 24),

              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: theme.colorScheme.surface,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: theme.colorScheme.outline.withValues(alpha: 0.3),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${s.created}: ${formatDateTime(widget.article.createdAt)}',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${s.updated}: ${formatDateTime(widget.article.updatedAt)}',
                      style: theme.textTheme.bodySmall?.copyWith(fontSize: 12),
                    ),
                  ],
                ),
              ),
            ],
          ),
          ),
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
            labelText: s.folder,
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
