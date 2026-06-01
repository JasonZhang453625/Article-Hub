import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
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
    // Check shortly after first frame so providers are ready and a SnackBar
    // has a Scaffold to attach to.
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
    final messenger = ScaffoldMessenger.of(context);
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 6),
        content: Text('Link found on clipboard: ${extractDomain(url)}'),
        action: SnackBarAction(
          label: 'Add',
          onPressed: () {
            context.push(AppRoutes.addArticle, extra: url);
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
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
