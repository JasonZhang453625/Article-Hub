import 'dart:async';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/passage.dart';
import '../../data/models/source_platform.dart';
import '../../data/services/processing_pipeline.dart';
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

  /// Subscription to live share intents. Cancelled in [dispose] to avoid a
  /// leak (and duplicate navigation if the screen is ever recreated).
  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Check shortly after first frame so providers are ready and a SnackBar
    // has a Scaffold to attach to.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _maybeDetectClipboardUrl();
      _handleInitialShare();
    });
    // receive_sharing_intent has no web implementation; subscribing to its
    // event channel on web raises an uncaught MissingPluginException that can
    // blank the first frame. Only wire up share listening on native platforms.
    if (!kIsWeb) {
      _listenForShareIntents();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _shareSub?.cancel();
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
        pipeline.process(article);
      }
    }
  }

  /// Handle share intent that launched the app (cold start).
  Future<void> _handleInitialShare() async {
    try {
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      if (initial.isEmpty || !mounted) return;
      final url = _extractUrlFromMedia(initial);
      if (url != null) {
        _navigateToAdd(url);
      }
    } catch (_) {
      // Ignore errors from share intent retrieval.
    }
  }

  /// Listen for share intents while the app is already running.
  void _listenForShareIntents() {
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (media) {
        if (media.isEmpty || !mounted) return;
        final url = _extractUrlFromMedia(media);
        if (url != null) {
          _navigateToAdd(url);
        }
      },
      // The platform channel may emit an error event on some platforms; absorb
      // it so it never becomes an uncaught async exception that breaks the UI.
      onError: (_) {},
    );
  }

  /// Extract the first valid URL from shared media items.
  String? _extractUrlFromMedia(List<SharedMediaFile> media) {
    for (final file in media) {
      final text = file.path.trim();
      if (text.isEmpty) continue;
      // Shared text may contain a URL among other content; try to find one.
      final url = _findUrlInText(text);
      if (url != null) return url;
    }
    return null;
  }

  /// Find a valid URL within a block of text.
  String? _findUrlInText(String text) {
    // Try the whole text first.
    final cleaned = cleanUrl(text);
    if (isValidUrl(cleaned)) return cleaned;
    // Fall back to scanning for URL patterns.
    final urlPattern = RegExp(r'https?://[^\s]+');
    final match = urlPattern.firstMatch(text);
    if (match != null) {
      final candidate = match.group(0);
      if (candidate != null) {
        final c = cleanUrl(candidate);
        if (isValidUrl(c)) return c;
      }
    }
    return null;
  }

  void _navigateToAdd(String url) {
    _quickSave(url);
  }

  /// Immediately save the URL as a pending article and kick off processing.
  /// If the URL already exists, navigate to the existing article instead.
  Future<void> _quickSave(String url) async {
    final s = ref.read(stringsProvider);
    final cleaned = cleanUrl(url);
    if (!isValidUrl(cleaned)) return;

    // URL deduplication — open existing article if already saved.
    final existing = ref.read(articlesProvider).valueOrNull;
    final duplicate = existing?.where((a) => a.url == cleaned).firstOrNull;
    if (duplicate != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${s.alreadySaved}: ${duplicate.title}')),
      );
      return;
    }

    final article = Article(
      id: const Uuid().v4(),
      url: cleaned,
      title: extractDomain(cleaned),
      source: SourcePlatform.fromUrl(cleaned),
      processingStatus: ProcessingStatus.pending,
    );

    await ref.read(articlesProvider.notifier).add(article);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.savedProcessing)),
    );

    // Fire-and-forget processing pipeline.
    _processArticle(article);
  }

  void _processArticle(Article article) {
    final s = ref.read(stringsProvider);
    final pipeline = ref.read(processingPipelineProvider);
    pipeline.process(article).then((result) {
      if (result != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.processingStatus == ProcessingStatus.completed
                  ? '${s.processed}: ${result.title}'
                  : '${s.failed}: ${result.processingError ?? "unknown error"}',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    });
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
          onPressed: () => _quickSave(url),
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
      floatingActionButton: DelayedReveal(
        delayMs: 220,
        beginOffset: const Offset(0, 0.18),
        child: FloatingActionButton.extended(
          onPressed: () {
            context.push(AppRoutes.addArticle);
          },
          icon: const Icon(Icons.add_rounded),
          label: Text(s.add),
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
                        child: Text('${s.failedToLoad}: $error'),
                      ),
                    ),
                    data: (articles) {
                      if (articles.isEmpty) {
                        return EmptyState(
                          message: s.noArticlesMatch,
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
                                    AppRoutes.summaryWithId(article.id),
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

            // ── Bottom-left buttons ──
            Positioned(
              left: 16,
              bottom: 24,
              child: Row(
                children: [
                  DelayedReveal(
                    delayMs: 260,
                    beginOffset: const Offset(0, 0.18),
                    child: Material(
                      color: Colors.transparent,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(20),
                        onTap: () {
                          context.push(AppRoutes.folders);
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
                            Icons.folder_rounded,
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
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
