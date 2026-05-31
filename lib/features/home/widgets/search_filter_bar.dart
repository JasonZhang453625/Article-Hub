import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/models/source_platform.dart';
import '../../../shared/providers/filter_providers.dart';
import '../../../shared/providers/passage_providers.dart';
import '../../../shared/providers/settings_providers.dart';
import 'filter_management_dialog.dart';

class SearchFilterBar extends ConsumerStatefulWidget {
  const SearchFilterBar({super.key});

  @override
  ConsumerState<SearchFilterBar> createState() => _SearchFilterBarState();
}

class _SearchFilterBarState extends ConsumerState<SearchFilterBar> {
  String? _draggingPlatformName;
  late final TextEditingController _searchController;

  @override
  void initState() {
    super.initState();
    // Initialise from the current query so the text survives navigating away
    // and back to the home screen.
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
    final selectedSource = ref.watch(selectedSourceProvider);
    final selectedFilterId = ref.watch(selectedFilterGroupProvider);
    final filtersAsync = ref.watch(filterGroupsProvider);
    final visiblePlatforms = ref.watch(visibleSourcePlatformsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final chipBg = isDark ? theme.colorScheme.surface : Colors.white;

    // If the currently selected source becomes hidden, clear the selection.
    // Done via listen (not inside build) to avoid mutating provider state
    // during a build pass.
    ref.listen<List<SourcePlatform>>(visibleSourcePlatformsProvider,
        (previous, next) {
      final current = ref.read(selectedSourceProvider);
      if (current.isNotEmpty &&
          !next.any((platform) => platform.name == current)) {
        ref.read(selectedSourceProvider.notifier).state = '';
      }
    });

    // Keep the text field in sync if the query is cleared elsewhere.
    ref.listen<String>(searchQueryProvider, (previous, next) {
      if (next != _searchController.text) {
        _searchController.text = next;
      }
    });

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
              controller: _searchController,
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
              ...visiblePlatforms.map((platform) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _SourcePlatformDragTarget(
                    platform: platform,
                    chipBg: chipBg,
                    isSelected: selectedSource == platform.name,
                    isDragging: _draggingPlatformName == platform.name,
                    onTap: () {
                      ref.read(selectedSourceProvider.notifier).state =
                          platform.name;
                      ref.read(selectedFilterGroupProvider.notifier).state =
                          '';
                    },
                    onAccepted: (draggedPlatformName) async {
                      await ref
                          .read(settingsProvider.notifier)
                          .moveSourcePlatformBefore(
                            draggedPlatformName,
                            platform.name,
                          );
                      if (mounted) {
                        setState(() {
                          _draggingPlatformName = null;
                        });
                      }
                    },
                    onDragStateChanged: (platformName) {
                      if (!mounted) return;
                      setState(() {
                        _draggingPlatformName = platformName;
                      });
                    },
                  ),
                );
              }),
              if (_draggingPlatformName != null && visiblePlatforms.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _SourceDropZone(
                    onAccept: () async {
                      final draggingPlatformName = _draggingPlatformName;
                      if (draggingPlatformName == null) return;
                      await ref
                          .read(settingsProvider.notifier)
                          .moveSourcePlatformToEnd(draggingPlatformName);
                      if (mounted) {
                        setState(() {
                          _draggingPlatformName = null;
                        });
                      }
                    },
                  ),
                ),
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

class _SourcePlatformDragTarget extends StatelessWidget {
  final SourcePlatform platform;
  final Color chipBg;
  final bool isSelected;
  final bool isDragging;
  final VoidCallback onTap;
  final Future<void> Function(String draggedPlatformName) onAccepted;
  final ValueChanged<String?> onDragStateChanged;

  const _SourcePlatformDragTarget({
    required this.platform,
    required this.chipBg,
    required this.isSelected,
    required this.isDragging,
    required this.onTap,
    required this.onAccepted,
    required this.onDragStateChanged,
  });

  @override
  Widget build(BuildContext context) {
    return DragTarget<String>(
      onWillAcceptWithDetails: (details) {
        return details.data != platform.name;
      },
      onAcceptWithDetails: (details) async {
        await onAccepted(details.data);
      },
      builder: (context, candidateData, rejectedData) {
        final isDropTargetActive = candidateData.isNotEmpty;
        final chip = _SourceChip(
          label: platform.displayName,
          icon: platform.icon,
          color: platform.accentColor,
          chipBg: chipBg,
          isSelected: isSelected,
          isDropTargetActive: isDropTargetActive,
          onTap: onTap,
        );

        return LongPressDraggable<String>(
          data: platform.name,
          dragAnchorStrategy: pointerDragAnchorStrategy,
          feedback: Material(
            color: Colors.transparent,
            child: _SourceChip(
              label: platform.displayName,
              icon: platform.icon,
              color: platform.accentColor,
              chipBg: chipBg,
              isSelected: true,
              onTap: () {},
            ),
          ),
          childWhenDragging: Opacity(
            opacity: 0.34,
            child: IgnorePointer(child: chip),
          ),
          onDragStarted: () => onDragStateChanged(platform.name),
          onDragEnd: (_) => onDragStateChanged(null),
          onDraggableCanceled: (velocity, offset) => onDragStateChanged(null),
          onDragCompleted: () => onDragStateChanged(null),
          child: AnimatedScale(
            duration: const Duration(milliseconds: 180),
            scale: isDragging ? 0.96 : 1,
            child: chip,
          ),
        );
      },
    );
  }
}

class _SourceDropZone extends StatelessWidget {
  final Future<void> Function() onAccept;

  const _SourceDropZone({required this.onAccept});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    return DragTarget<String>(
      onWillAcceptWithDetails: (details) => true,
      onAcceptWithDetails: (_) async {
        await onAccept();
      },
      builder: (context, candidateData, rejectedData) {
        final isActive = candidateData.isNotEmpty;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: isActive
                ? theme.colorScheme.primary.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: isActive
                  ? theme.colorScheme.primary
                  : (isDark
                      ? Colors.white24
                      : const Color(0xFFD7E3EA)),
            ),
          ),
          child: Row(
            children: [
              Icon(
                Icons.east_rounded,
                size: 16,
                color: isActive
                    ? theme.colorScheme.primary
                    : (isDark ? Colors.white54 : const Color(0xFF6C8594)),
              ),
              const SizedBox(width: 6),
              Text(
                'End',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: isActive
                      ? theme.colorScheme.primary
                      : (isDark ? Colors.white54 : const Color(0xFF6C8594)),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _SourceChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final Color chipBg;
  final bool isSelected;
  final bool isDropTargetActive;
  final VoidCallback onTap;

  const _SourceChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.chipBg,
    required this.isSelected,
    required this.onTap,
    this.isDropTargetActive = false,
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
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: selectedFillColor,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: isDropTargetActive
                    ? theme.colorScheme.primary
                    : (isSelected ? color : color.withValues(alpha: 0.22)),
                width: isDropTargetActive ? 1.4 : 1,
              ),
              boxShadow: isDropTargetActive
                  ? [
                      BoxShadow(
                        color: theme.colorScheme.primary.withValues(alpha: 0.16),
                        blurRadius: 16,
                        offset: const Offset(0, 8),
                      ),
                    ]
                  : null,
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
    final isAllChip = label.toLowerCase() == 'all';
    if (isDark && isAllChip) {
      return const Color(0xFF384654);
    }

    return color;
  }
}
