import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../data/models/passage.dart';
import '../../shared/providers/pipeline_provider.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/url_helpers.dart';
import '../../config/routes.dart';
import 'widgets/passage_card.dart';
import 'widgets/search_filter_bar.dart';
import 'widgets/empty_state.dart';
import 'widgets/home_header.dart';
import '../../shared/widgets/delayed_reveal.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  /// URLs already offered this session, so the same clipboard link isn't
  /// suggested repeatedly.
  final Set<String> _handledClipboardUrls = {};
  bool _checkingClipboard = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeDetectClipboardUrl();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeDetectClipboardUrl();
      _resumePendingArticles();
    }
  }

  /// Resume processing for any articles that are pending or failed.
  void _resumePendingArticles() {
    final articles = ref.read(articlesProvider).valueOrNull;
    if (articles == null) return;
    final pipeline = ref.read(processingPipelineProvider);
    for (final article in articles) {
      if (article.processingStatus == ProcessingStatus.pending ||
          article.processingStatus == ProcessingStatus.failed) {
        pipeline.process(article).catchError((_) => null);
      }
    }
  }

  Future<void> _maybeDetectClipboardUrl() async {
    if (_checkingClipboard) return;
    if (!ref.read(clipboardDetectionEnabledProvider)) return;
    _checkingClipboard = true;
    try {
      final data = await Clipboard.getData('text/plain');
      final text = data?.text?.trim();
      if (text == null || text.isEmpty) return;

      final cleaned = cleanUrl(text);
      if (!isValidUrl(cleaned)) return;
      if (_handledClipboardUrls.contains(cleaned)) return;

      // Don't suggest links the user has already saved.
      final existing = ref.read(articlesProvider).valueOrNull;
      if (existing != null && existing.any((a) => a.url == cleaned)) {
        _handledClipboardUrls.add(cleaned);
        return;
      }

      _handledClipboardUrls.add(cleaned);
      if (!mounted) return;
      _showClipboardSuggestion(cleaned);
    } catch (_) {
      // Clipboard may be inaccessible (permissions); ignore silently.
    } finally {
      _checkingClipboard = false;
    }
  }

  void _showClipboardSuggestion(String url) {
    final s = ref.read(stringsProvider);
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('${s.clipboardLink}: ${extractDomain(url)}'),
        action: SnackBarAction(
          label: s.clipboardSave,
          onPressed: () {
            context.push(AppRoutes.addArticle, extra: url);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final filteredArticles = ref.watch(filteredArticlesProvider);
    final headerVisibilityAsync = ref.watch(homeHeaderVisibilityProvider);
    final showHeader = headerVisibilityAsync.maybeWhen(
      data: (isVisible) => isVisible,
      orElse: () => false,
    );

    return Scaffold(
      floatingActionButton: null,
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
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text('${s.failedToLoad}: $error'),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: () => ref.invalidate(articlesProvider),
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                    data: (articles) {
                      if (articles.isEmpty) {
                        return EmptyState(
                          message: s.noArticlesMatch,
                        );
                      }
                      return LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth >= 720) {
                            return RefreshIndicator(
                              onRefresh: () async {
                                ref
                                    .read(articlesProvider.notifier)
                                    .refresh();
                              },
                              child: GridView.builder(
                                physics: const AlwaysScrollableScrollPhysics(),
                                padding: const EdgeInsets.only(
                                    top: 8, bottom: 104, left: 16, right: 16),
                                gridDelegate:
                                    const SliverGridDelegateWithMaxCrossAxisExtent(
                                  maxCrossAxisExtent: 400,
                                  mainAxisSpacing: 12,
                                  crossAxisSpacing: 12,
                                  childAspectRatio: 0.85,
                                ),
                                itemCount: articles.length,
                                itemBuilder: (context, index) {
                                  final article = articles[index];
                                  return DelayedReveal(
                                    delayMs: 110 +
                                        (index * 42).clamp(0, 260),
                                    beginOffset:
                                        const Offset(0, 0.08),
                                    child: ArticleCard(
                                      article: article,
                                      onTap: () {
                                        context.push(
                                          AppRoutes.summaryWithId(
                                              article.id),
                                          extra: article,
                                        );
                                      },
                                      onInfoTap: () {
                                        context.push(
                                          AppRoutes.detailWithId(
                                              article.id),
                                          extra: article,
                                        );
                                      },
                                    ),
                                  );
                                },
                              ),
                            );
                          }
                          return RefreshIndicator(
                            onRefresh: () async {
                              ref
                                  .read(articlesProvider.notifier)
                                  .refresh();
                            },
                            child: ListView.builder(
                              physics:
                                  const AlwaysScrollableScrollPhysics(),
                              padding:
                                  const EdgeInsets.only(top: 8, bottom: 104),
                              itemCount: articles.length,
                              itemBuilder: (context, index) {
                                final article = articles[index];
                                return DelayedReveal(
                                  delayMs:
                                      110 + (index * 42).clamp(0, 260),
                                  beginOffset:
                                      const Offset(0, 0.08),
                                  child: ArticleCard(
                                    article: article,
                                    onTap: () {
                                      context.push(
                                        AppRoutes.summaryWithId(
                                            article.id),
                                        extra: article,
                                      );
                                    },
                                    onInfoTap: () {
                                      context.push(
                                        AppRoutes.detailWithId(
                                            article.id),
                                        extra: article,
                                      );
                                    },
                                  ),
                                );
                              },
                            ),
                          );
                        },
                      );
                    },
                  ),
                ),
              ],
            ),

            // ── Bottom buttons ──
            Positioned(
              left: 16,
              bottom: 24,
              child: DelayedReveal(
                delayMs: 260,
                beginOffset: const Offset(0, 0.18),
                child: FloatingActionButton(
                  heroTag: const Object(),
                  onPressed: () {
                    context.push(AppRoutes.folders);
                  },
                  child: const Icon(Icons.folder_rounded),
                ),
              ),
            ),
            Positioned(
              right: 16,
              bottom: 24,
              child: DelayedReveal(
                delayMs: 220,
                beginOffset: const Offset(0, 0.18),
                child: FloatingActionButton.extended(
                  heroTag: const Object(),
                  onPressed: () {
                    context.push(AppRoutes.addArticle);
                  },
                  icon: const Icon(Icons.add_rounded),
                  label: Text(s.add),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
