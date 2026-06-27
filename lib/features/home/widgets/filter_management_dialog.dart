import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../data/models/filter_group.dart';
import '../../../shared/providers/filter_providers.dart';
import '../../../shared/providers/locale_provider.dart';
import '../../../shared/providers/settings_providers.dart';
import '../../../shared/utils/locale_strings.dart';

/// A full-screen dialog for creating or editing a filter group.
class FilterEditDialog extends ConsumerStatefulWidget {
  final FilterGroup? existing;

  const FilterEditDialog({super.key, this.existing});

  @override
  ConsumerState<FilterEditDialog> createState() => _FilterEditDialogState();
}

class _FilterEditDialogState extends ConsumerState<FilterEditDialog> {
  late TextEditingController _nameController;
  late TextEditingController _tagController;
  late List<String> _tagPatterns;
  late Set<String> _selectedSources;

  bool get isEditing => widget.existing != null;

  @override
  void initState() {
    super.initState();
    _nameController =
        TextEditingController(text: widget.existing?.name ?? '');
    _tagController = TextEditingController();
    _tagPatterns = List.from(widget.existing?.tagPatterns ?? []);
    _selectedSources = Set.from(widget.existing?.sourcePlatforms ?? []);
  }

  @override
  void dispose() {
    _nameController.dispose();
    _tagController.dispose();
    super.dispose();
  }

  void _addTag() {
    final text = _tagController.text.trim();
    if (text.isNotEmpty && !_tagPatterns.contains(text)) {
      setState(() {
        _tagPatterns.add(text);
      });
      _tagController.clear();
    }
  }

  Future<void> _save() async {
    final s = ref.read(stringsProvider);
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(s.pleaseEnterName)),
      );
      return;
    }

    final group = FilterGroup(
      id: widget.existing?.id ?? const Uuid().v4(),
      name: name,
      tagPatterns: _tagPatterns,
      sourcePlatforms: _selectedSources.toList(),
    );

    if (isEditing) {
      await ref.read(filterGroupsProvider.notifier).update(group);
    } else {
      await ref.read(filterGroupsProvider.notifier).add(group);
    }

    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final visiblePlatforms = ref.watch(visibleSourcePlatformsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(isEditing ? s.editFilter : s.newFilter),
        actions: [
          TextButton(
            onPressed: _save,
            child: Text(s.save),
          ),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Name field
            TextFormField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: s.filterName,
                hintText: s.filterNameHint,
                prefixIcon: const Icon(Icons.filter_alt_rounded),
              ),
            ),
            const SizedBox(height: 20),

            // Tag patterns
            Text(s.tagKeywords,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              s.tagKeywordsDesc,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isDark ? Colors.white54 : const Color(0xFF6C8594),
              ),
            ),
            const SizedBox(height: 10),
            TextFormField(
              controller: _tagController,
              decoration: InputDecoration(
                labelText: s.addTagKeyword,
                prefixIcon: const Icon(Icons.tag),
                suffixIcon: IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: _addTag,
                ),
              ),
              onFieldSubmitted: (_) => _addTag(),
            ),
            if (_tagPatterns.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 10),
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: _tagPatterns.map((tag) {
                    return Chip(
                      label: Text(tag),
                      deleteIcon: const Icon(Icons.close, size: 16),
                      onDeleted: () {
                        setState(() {
                          _tagPatterns.remove(tag);
                        });
                      },
                    );
                  }).toList(),
                ),
              ),
            const SizedBox(height: 24),

            // Source platforms
            Text(s.sourcePlatformsFilter,
                style: theme.textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(
              s.sourcePlatformsDesc,
              style: theme.textTheme.bodySmall?.copyWith(
                color: isDark ? Colors.white54 : const Color(0xFF6C8594),
              ),
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: visiblePlatforms.map((platform) {
                final selected = _selectedSources.contains(platform.name);
                return FilterChip(
                  avatar: Icon(platform.icon,
                      size: 16, color: platform.accentColor),
                  label: Text(platform.displayName),
                  selected: selected,
                  selectedColor:
                      platform.accentColor.withValues(alpha: 0.15),
                  checkmarkColor: platform.accentColor,
                  onSelected: (value) {
                    setState(() {
                      if (value) {
                        _selectedSources.add(platform.name);
                      } else {
                        _selectedSources.remove(platform.name);
                      }
                    });
                  },
                );
              }).toList(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Bottom sheet that lists all filter groups with options to add/edit/delete.
class FilterManagementSheet extends ConsumerWidget {
  const FilterManagementSheet({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final filtersAsync = ref.watch(filterGroupsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.3,
      maxChildSize: 0.85,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: theme.scaffoldBackgroundColor,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(24),
            ),
          ),
          child: Column(
            children: [
              // Handle bar
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 6),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: isDark ? Colors.white24 : const Color(0xFFD7E3EA),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
                child: Row(
                  children: [
                    Text(
                      s.manageFilters,
                      style: theme.textTheme.titleLarge,
                    ),
                    const Spacer(),
                    FilledButton.icon(
                      onPressed: () {
                        Navigator.of(context).pop();
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const FilterEditDialog(),
                          ),
                        );
                      },
                      icon: const Icon(Icons.add, size: 18),
                      label: Text(s.newButton),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: filtersAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (e, _) => Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Padding(
                          padding: const EdgeInsets.all(16),
                          child: Text('Error: $e'),
                        ),
                        const SizedBox(height: 8),
                        FilledButton.icon(
                          onPressed: () => ref.invalidate(filterGroupsProvider),
                          icon: const Icon(Icons.refresh, size: 18),
                          label: const Text('Retry'),
                        ),
                      ],
                    ),
                  ),
                  data: (groups) {
                    if (groups.isEmpty) {
                      return Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.filter_alt_off_rounded,
                                size: 48,
                                color: isDark
                                    ? Colors.white24
                                    : const Color(0xFFB0C6D0)),
                            const SizedBox(height: 12),
                            Text(
                              s.noCustomFilters,
                              style: theme.textTheme.bodyMedium,
                            ),
                          ],
                        ),
                      );
                    }
                    return ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 12),
                      itemCount: groups.length,
                      separatorBuilder: (_, a) =>
                          const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final group = groups[index];
                        return Container(
                          padding: const EdgeInsets.all(14),
                          decoration: BoxDecoration(
                            color: theme.colorScheme.surface,
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color:
                                  theme.colorScheme.outline.withValues(alpha: 0.3),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.filter_alt_rounded,
                                  size: 20,
                                  color: theme.colorScheme.primary),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      group.name,
                                      style: theme.textTheme.titleMedium
                                          ?.copyWith(fontSize: 15),
                                    ),
                                    const SizedBox(height: 2),
                                    Text(
                                      _buildSubtitle(group, s),
                                      style: theme.textTheme.bodySmall
                                          ?.copyWith(
                                        color: isDark
                                            ? Colors.white54
                                            : const Color(0xFF6C8594),
                                      ),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                icon: const Icon(Icons.edit_outlined,
                                    size: 18),
                                onPressed: () {
                                  Navigator.of(context).pop();
                                  Navigator.of(context).push(
                                    MaterialPageRoute(
                                      builder: (_) => FilterEditDialog(
                                          existing: group),
                                    ),
                                  );
                                },
                              ),
                              IconButton(
                                icon: Icon(Icons.delete_outline,
                                    size: 18,
                                    color: Colors.red[400]),
                                onPressed: () async {
                                  await ref
                                      .read(
                                          filterGroupsProvider.notifier)
                                      .delete(group.id);
                                },
                              ),
                            ],
                          ),
                        );
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  String _buildSubtitle(FilterGroup group, LocaleStrings s) {
    final parts = <String>[];
    if (group.tagPatterns.isNotEmpty) {
      parts.add('Tags: ${group.tagPatterns.join(", ")}');
    }
    if (group.sourcePlatforms.isNotEmpty) {
      parts.add('Sources: ${group.sourcePlatforms.length}');
    }
    if (parts.isEmpty) return s.allArticles;
    return parts.join('  •  ');
  }
}
