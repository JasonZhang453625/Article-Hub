import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../shared/providers/passage_providers.dart';
import '../../config/routes.dart';
import 'widgets/passage_card.dart';
import 'widgets/search_filter_bar.dart';
import 'widgets/empty_state.dart';
import 'widgets/home_header.dart';
import '../../shared/widgets/delayed_reveal.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filteredArticles = ref.watch(filteredArticlesProvider);
    final headerVisibilityAsync = ref.watch(homeHeaderVisibilityProvider);
    final showHeader = headerVisibilityAsync.maybeWhen(
      data: (isVisible) => isVisible,
      orElse: () => false,
    );

    return Scaffold(
      floatingActionButton: DelayedReveal(
        delayMs: 220,
        beginOffset: const Offset(0, 0.18),
        child: FloatingActionButton.extended(
          onPressed: () {
            context.push(AppRoutes.addArticle);
          },
          icon: const Icon(Icons.add_rounded),
          label: const Text('Add'),
        ),
      ),
      body: SafeArea(
        child: Stack(
          children: [
            Column(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeOutCubic,
                  child: showHeader
                      ? DelayedReveal(
                          key: const ValueKey('home-header'),
                          child: HomeHeader(
                            onClose: () {
                              ref
                                  .read(homeHeaderVisibilityProvider.notifier)
                                  .dismiss();
                            },
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                const DelayedReveal(delayMs: 80, child: SearchFilterBar()),
                Expanded(
                  child: filteredArticles.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (error, stack) => Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text('Failed to load articles: $error'),
                      ),
                    ),
                    data: (articles) {
                      if (articles.isEmpty) {
                        return const EmptyState(
                          message: 'No articles match the current filters',
                        );
                      }
                      return RefreshIndicator(
                        onRefresh: () async {
                          ref.read(articlesProvider.notifier).refresh();
                        },
                        child: ListView.builder(
                          physics: const AlwaysScrollableScrollPhysics(),
                          padding:
                              const EdgeInsets.only(top: 8, bottom: 104),
                          itemCount: articles.length,
                          itemBuilder: (context, index) {
                            final article = articles[index];
                            return DelayedReveal(
                              delayMs:
                                  110 + (index * 42).clamp(0, 260),
                              beginOffset: const Offset(0, 0.08),
                              child: ArticleCard(
                                article: article,
                                onTap: () {
                                  context.push(
                                    AppRoutes.readerWithId(article.id),
                                    extra: article,
                                  );
                                },
                                onInfoTap: () {
                                  context.push(
                                    AppRoutes.detailWithId(article.id),
                                    extra: article,
                                  );
                                },
                              ),
                            );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),

            // ── Settings button (bottom-left) ──
            Positioned(
              left: 16,
              bottom: 24,
              child: DelayedReveal(
                delayMs: 260,
                beginOffset: const Offset(0, 0.18),
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(20),
                    onTap: () {
                      context.push(AppRoutes.settings);
                    },
                    child: Ink(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.surface,
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .outline
                              .withValues(alpha: 0.3),
                        ),
                      ),
                      child: Icon(
                        Icons.settings_rounded,
                        size: 22,
                        color: Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
