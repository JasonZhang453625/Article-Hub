import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../data/models/source_platform.dart';
import '../../../shared/providers/passage_providers.dart';

class SearchFilterBar extends ConsumerWidget {
  const SearchFilterBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final selectedPlatform = ref.watch(selectedPlatformProvider);

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: TextField(
            decoration: InputDecoration(
              hintText: 'Search passages...',
              prefixIcon: const Icon(Icons.search),
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(vertical: 10),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            onChanged: (value) {
              ref.read(searchQueryProvider.notifier).state = value;
            },
          ),
        ),
        SizedBox(
          height: 44,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            children: [
              _buildChip(
                label: 'All',
                isSelected: selectedPlatform.isEmpty,
                onSelected: (_) {
                  ref.read(selectedPlatformProvider.notifier).state = '';
                },
              ),
              ...SourcePlatform.values.map((platform) {
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: _buildChip(
                    label: platform.displayName,
                    isSelected: selectedPlatform == platform.name,
                    onSelected: (_) {
                      ref.read(selectedPlatformProvider.notifier).state =
                          platform.name;
                    },
                  ),
                );
              }),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildChip({
    required String label,
    required bool isSelected,
    required ValueChanged<bool> onSelected,
  }) {
    return FilterChip(
      label: Text(label),
      selected: isSelected,
      onSelected: onSelected,
      showCheckmark: false,
      visualDensity: VisualDensity.compact,
      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
  }
}
