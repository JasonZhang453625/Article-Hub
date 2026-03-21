import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/source_platform.dart';
import '../../../shared/providers/passage_providers.dart';
import '../../../shared/providers/filter_providers.dart';
import 'filter_management_dialog.dart';

class SearchFilterBar extends ConsumerWidget {
  const SearchFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedSource = ref.watch(selectedSourceProvider);
    final selectedFilterId = ref.watch(selectedFilterGroupProvider);
    final filtersAsync = ref.watch(filterGroupsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chipBg = isDark ? theme.colorScheme.surface : Colors.white;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 6),
          child: Container(
            decoration: BoxDecoration(
              color: chipBg,
              borderRadius: BorderRadius.circular(24),
            ),
            child: TextField(
              decoration: const InputDecoration(
                hintText: 'Search articles, tags or notes...',
                prefixIcon: Icon(Icons.search_rounded),
                suffixIcon: Icon(Icons.tune_rounded),
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 16),
              ),
              onChanged: (value) {
                ref.read(searchQueryProvider.notifier).state = value;
              },
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
                label: 'All',
                icon: Icons.grid_view_rounded,
                color: theme.colorScheme.onSurface,
                chipBg: chipBg,
                isSelected:
                    selectedSource.isEmpty && selectedFilterId.isEmpty,
                onTap: () {
                  ref.read(selectedSourceProvider.notifier).state = '';
                  ref.read(selectedFilterGroupProvider.notifier).state = '';
                },
              ),
              ...SourcePlatform.values.map((platform) {
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
                      ref.read(selectedFilterGroupProvider.notifier).state =
                          '';
                    },
                  ),
                );
              }),

              // ── Separator ──
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 6, vertical: 12),
                child: Container(
                  width: 1,
                  color: isDark ? Colors.white12 : const Color(0xFFD7E3EA),
                ),
              ),

              // ── Custom filter group chips ──
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
                        ref.read(selectedSourceProvider.notifier).state =
                            '';
                        ref
                            .read(selectedFilterGroupProvider.notifier)
                            .state = group.id;
                      },
                    ),
                  );
                }),
                orElse: () => <Widget>[],
              ),

              // ── Manage filters button ──
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
                          horizontal: 12, vertical: 10),
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
                          Icon(Icons.edit_rounded,
                              size: 16,
                              color: isDark
                                  ? Colors.white54
                                  : const Color(0xFF6C8594)),
                          const SizedBox(width: 6),
                          Text(
                            'Manage',
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
  final VoidCallback onTap;

  const _SourceChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.chipBg,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: onTap,
          child: Ink(
            padding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: isSelected ? color : chipBg,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color:
                    isSelected ? color : color.withValues(alpha: 0.22),
              ),
            ),
            child: Row(
              children: [
                Icon(icon,
                    size: 16,
                    color: isSelected ? Colors.white : color),
                const SizedBox(width: 8),
                Text(
                  label,
                  style: TextStyle(
                    color: isSelected
                        ? Colors.white
                        : Theme.of(context).colorScheme.onSurface,
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
}
