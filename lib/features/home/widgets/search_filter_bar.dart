import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/source_platform.dart';
import '../../../shared/providers/filter_providers.dart';
import '../../../shared/providers/locale_provider.dart';
import '../../../shared/providers/passage_providers.dart';
import '../../../shared/providers/settings_providers.dart';
import 'filter_management_dialog.dart';

class SearchFilterBar extends ConsumerStatefulWidget {
  const SearchFilterBar({super.key});

  @override
  ConsumerState<SearchFilterBar> createState() => _SearchFilterBarState();
}

class _SearchFilterBarState extends ConsumerState<SearchFilterBar> {
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    _searchController =
        TextEditingController(text: ref.read(searchQueryProvider));
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final selectedSource = ref.watch(selectedSourceProvider);
    final selectedFilterId = ref.watch(selectedFilterGroupProvider);
    final selectedFolderId = ref.watch(selectedFolderIdProvider);
    final foldersAsync = ref.watch(foldersProvider);
    final filtersAsync = ref.watch(filterGroupsProvider);
    final visiblePlatforms = ref.watch(visibleSourcePlatformsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chipBg = isDark ? theme.colorScheme.surface : Colors.white;

    ref.listen<List<SourcePlatform>>(visibleSourcePlatformsProvider,
        (previous, next) {
      final current = ref.read(selectedSourceProvider);
      if (current.isNotEmpty &&
          !next.any((platform) => platform.name == current)) {
        ref.read(selectedSourceProvider.notifier).state = '';
      }
    });

    ref.listen<String>(searchQueryProvider, (previous, next) {
      if (next != _searchController.text) {
        _searchController.text = next;
      }
    });

    return Column(
      children: [
        GestureDetector(
          onTap: () => FocusScope.of(context).unfocus(),
          behavior: HitTestBehavior.translucent,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
            child: Container(
              decoration: BoxDecoration(
                color: chipBg,
                borderRadius: BorderRadius.circular(24),
              ),
              child: TextField(
                controller: _searchController,
                decoration: InputDecoration(
                  hintText: s.searchHint,
                  prefixIcon: const Icon(Icons.search_rounded),
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onChanged: (value) {
                  ref.read(searchQueryProvider.notifier).state = value;
                },
              ),
            ),
          ),
        ),
        SizedBox(
          height: 48,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _SourceChip(
                label: s.filterAll,
                icon: Icons.grid_view_rounded,
                color: theme.colorScheme.onSurface,
                chipBg: chipBg,
                isAllChip: true,
                isSelected:
                    selectedSource.isEmpty && selectedFilterId.isEmpty && selectedFolderId.isEmpty,
                onTap: () {
                  ref.read(selectedSourceProvider.notifier).state = '';
                  ref.read(selectedFilterGroupProvider.notifier).state = '';
                  ref.read(selectedFolderIdProvider.notifier).state = '';
                },
              ),
              ...visiblePlatforms.map((platform) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _SourceChip(
                    label: platform.displayName,
                    icon: platform.icon,
                    color: platform.accentColor,
                    chipBg: chipBg,
                    isSelected: selectedSource == platform.name,
                    onTap: () {
                      ref.read(selectedSourceProvider.notifier).state =
                          platform.name;
                      ref.read(selectedFilterGroupProvider.notifier).state = '';
                    },
                  ),
                );
              }),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                child: Container(
                  width: 1,
                  color: isDark ? Colors.white12 : const Color(0xFFD7E3EA),
                ),
              ),
              if (selectedFolderId.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _SourceChip(
                    label: foldersAsync.maybeWhen(
                      data: (folders) => folders
                          .where((f) => f.id == selectedFolderId)
                          .firstOrNull
                          ?.name ?? s.filterAll,
                      orElse: () => s.filterAll,
                    ),
                    icon: Icons.folder_rounded,
                    color: theme.colorScheme.tertiary,
                    chipBg: chipBg,
                    isSelected: true,
                    onTap: () {
                      ref.read(selectedFolderIdProvider.notifier).state = '';
                    },
                  ),
                ),
              if (selectedFolderId.isNotEmpty)
                Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 12),
                  child: Container(
                    width: 1,
                    color: isDark ? Colors.white12 : const Color(0xFFD7E3EA),
                  ),
                ),
              ...filtersAsync.maybeWhen(
                data: (groups) => groups.map((group) {
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4),
                    child: _SourceChip(
                      label: group.name,
                      icon: Icons.filter_alt_rounded,
                      color: theme.colorScheme.primary,
                      chipBg: chipBg,
                      isSelected: selectedFilterId == group.id,
                      onTap: () {
                        ref.read(selectedSourceProvider.notifier).state = '';
                        ref
                            .read(selectedFilterGroupProvider.notifier)
                            .state = group.id;
                      },
                    ),
                  );
                }),
                orElse: () => <Widget>[],
              ),
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () {
                      showModalBottomSheet(
                        context: context,
                        isScrollControlled: true,
                        backgroundColor: Colors.transparent,
                        builder: (_) => const FilterManagementSheet(),
                      );
                    },
                    child: Ink(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: isDark
                              ? Colors.white12
                              : const Color(0xFFD7E3EA),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.edit_rounded,
                            size: 16,
                            color: isDark
                                ? Colors.white54
                                : const Color(0xFF6C8594),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            s.manage,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: isDark
                                  ? Colors.white54
                                  : const Color(0xFF6C8594),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _SourceChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final Color chipBg;
  final bool isSelected;
  final bool isAllChip;
  final VoidCallback onTap;

  const _SourceChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.chipBg,
    required this.isSelected,
    required this.onTap,
    this.isAllChip = false,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final selectedFillColor = isSelected ? _selectedFillColor(isDark) : chipBg;
    final unselectedTextColor = isDark
        ? theme.colorScheme.onSurface.withValues(alpha: 0.9)
        : theme.colorScheme.onSurface;
    final unselectedIconColor =
        isDark && label == 'X' ? Colors.white : color;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Ink(
            padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8.5),
            decoration: BoxDecoration(
              color: selectedFillColor,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: isSelected ? color : color.withValues(alpha: 0.22),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 16,
                  color: isSelected ? Colors.white : unselectedIconColor,
                ),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 13,
                    color: isSelected ? Colors.white : unselectedTextColor,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _selectedFillColor(bool isDark) {
    if (isDark && isAllChip) {
      return const Color(0xFF384654);
    }
    return color;
  }
}
