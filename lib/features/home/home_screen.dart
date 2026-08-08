import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../data/models/passage.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/filter_providers.dart';
import '../../shared/providers/home_navigation_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/url_helpers.dart';
import '../../shared/utils/breakpoints.dart';
import '../../shared/utils/snackbar_helpers.dart';
import '../../config/routes.dart';
import 'widgets/passage_card.dart';
import 'widgets/search_filter_bar.dart';
import 'widgets/empty_state.dart';
import 'widgets/home_header.dart';
import 'widgets/detail_pane.dart';
import '../../shared/widgets/delayed_reveal.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  final _articleScrollController = ScrollController();

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
    _articleScrollController.dispose();
    super.dispose();
  }

  void _returnToAllAndScrollToTop() {
    ref.read(selectedSourceProvider.notifier).state = '';
    ref.read(selectedFilterGroupProvider.notifier).state = '';
    ref.read(selectedFolderIdProvider.notifier).state = '';

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_articleScrollController.hasClients) return;
      final position = _articleScrollController.position;
      if (position.pixels <= position.minScrollExtent) return;
      _articleScrollController.animateTo(
        position.minScrollExtent,
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
      );
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _maybeDetectClipboardUrl();
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
    showAppSnackBar(
      context,
      message: '${s.clipboardLink}: ${extractDomain(url)}',
      clearExisting: true,
      action: SnackBarAction(
        label: s.clipboardSave,
        onPressed: () {
          context.push(AppRoutes.addArticle, extra: url);
        },
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

    ref.listen<int>(homeScrollToTopRequestProvider, (previous, next) {
      if (previous != next) {
        _returnToAllAndScrollToTop();
      }
    });

    return Scaffold(
      floatingActionButton: null,
      body: SafeArea(
        child: Column(
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
                loading: () => const Center(child: CircularProgressIndicator()),
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
                    return EmptyState(message: s.noArticlesMatch);
                  }
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      final isMasterDetail =
                          constraints.maxWidth >= desktopBreakpoint;

                      final articleList = _ArticleListView(
                        articles: articles,
                        isMasterDetail: isMasterDetail,
                        scrollController: _articleScrollController,
                      );

                      if (!isMasterDetail) {
                        return articleList;
                      }

                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(flex: 2, child: articleList),
                          const VerticalDivider(width: 1, thickness: 1),
                          const Expanded(
                            flex: 3,
                            child: ClipRect(child: DetailPane()),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ArticleListView extends ConsumerWidget {
  final List<Article> articles;
  final bool isMasterDetail;
  final ScrollController scrollController;

  const _ArticleListView({
    required this.articles,
    required this.isMasterDetail,
    required this.scrollController,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Stack(
      children: [
        RefreshIndicator(
          onRefresh: () async {
            ref.read(articlesProvider.notifier).refresh();
          },
          child: ListView.builder(
            controller: scrollController,
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.only(top: 8, bottom: 104),
            itemCount: articles.length,
            itemBuilder: (context, index) {
              final article = articles[index];
              final selectedId = isMasterDetail
                  ? ref.watch(selectedArticleIdProvider)
                  : null;
              return DelayedReveal(
                delayMs: 110 + (index * 42).clamp(0, 260),
                beginOffset: const Offset(0, 0.08),
                child: ArticleCard(
                  article: article,
                  isSelected: isMasterDetail && selectedId == article.id,
                  onTap: () {
                    if (isMasterDetail) {
                      if (selectedId == article.id) {
                        ref.read(selectedArticleIdProvider.notifier).state =
                            null;
                      } else {
                        ref.read(selectedArticleIdProvider.notifier).state =
                            article.id;
                      }
                    } else {
                      context.push(
                        AppRoutes.summaryWithId(article.id),
                        extra: article,
                      );
                    }
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
        ),
        Positioned(
          left: 16,
          bottom: 24,
          child: DelayedReveal(
            delayMs: 260,
            beginOffset: const Offset(0, 0.18),
            child: Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: FloatingActionButton(
                heroTag: const Object(),
                onPressed: () {
                  context.push(AppRoutes.folders);
                },
                child: const Icon(Icons.folder_rounded),
              ),
            ),
          ),
        ),
        Positioned(
          right: 16,
          bottom: 24,
          child: DelayedReveal(
            delayMs: 220,
            beginOffset: const Offset(0, 0.18),
            child: Container(
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(999),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.12),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: FloatingActionButton.extended(
                heroTag: const Object(),
                onPressed: () {
                  context.push(AppRoutes.addArticle);
                },
                icon: const Icon(Icons.add_rounded),
                label: Text(ref.watch(stringsProvider).add),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
