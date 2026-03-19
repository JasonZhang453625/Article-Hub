import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../shared/providers/passage_providers.dart';
import '../../config/routes.dart';
import 'widgets/passage_card.dart';
import 'widgets/search_filter_bar.dart';
import 'widgets/empty_state.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filteredPassages = ref.watch(filteredPassagesProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Passages'),
      ),
      body: Column(
        children: [
          const SearchFilterBar(),
          Expanded(
            child: filteredPassages.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (error, stack) => Center(
                child: Text('Error: $error'),
              ),
              data: (passages) {
                if (passages.isEmpty) {
                  return const EmptyState(
                    message: 'No passages found',
                  );
                }
                return RefreshIndicator(
                  onRefresh: () async {
                    ref.read(passagesProvider.notifier).refresh();
                  },
                  child: ListView.builder(
                    padding: const EdgeInsets.only(top: 8, bottom: 80),
                    itemCount: passages.length,
                    itemBuilder: (context, index) {
                      final passage = passages[index];
                      return PassageCard(
                        passage: passage,
                        onTap: () {
                          context.push(
                            AppRoutes.readerWithId(passage.id),
                            extra: passage,
                          );
                        },
                        onInfoTap: () {
                          context.push(
                            AppRoutes.detailWithId(passage.id),
                            extra: passage,
                          );
                        },
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          context.push(AppRoutes.addPassage);
        },
        child: const Icon(Icons.add),
      ),
    );
  }
}
