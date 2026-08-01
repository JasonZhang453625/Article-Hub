import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import 'dart:io';

import '../../data/models/passage.dart';
import '../../data/services/attachment_store.dart';
import 'package:pdfrx/pdfrx.dart';
import '../../data/services/headless_webview_page_loader.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/providers/locale_provider.dart';

/// A failed image, iframe, ad, or analytics request must not replace an
/// otherwise healthy page with the full-page error state.
bool shouldTreatWebResourceErrorAsPageFailure(bool? isForMainFrame) {
  return isForMainFrame == true;
}

InAppWebViewSettings createReaderWebViewSettings(int webZoom) {
  return InAppWebViewSettings(
    userAgent: articleHubMobileUserAgent,
    javaScriptEnabled: true,
    useShouldOverrideUrlLoading: true,
    supportZoom: true,
    useWideViewPort: true,
    builtInZoomControls: true,
    displayZoomControls: false,
    allowsInlineMediaPlayback: true,
    mediaPlaybackRequiresUserGesture: false,
    textZoom: webZoom,
  );
}

class ReaderWebViewSurface extends StatelessWidget {
  final Widget webView;
  final Widget? errorOverlay;

  const ReaderWebViewSurface({
    super.key,
    required this.webView,
    this.errorOverlay,
  });

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        webView,
        if (errorOverlay != null)
          ColoredBox(
            color: Theme.of(context).scaffoldBackgroundColor,
            child: errorOverlay!,
          ),
      ],
    );
  }
}

class ReaderScreen extends ConsumerStatefulWidget {
  final Article article;

  const ReaderScreen({super.key, required this.article});

  @override
  ConsumerState<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends ConsumerState<ReaderScreen> {
  double _progress = 0;
  InAppWebViewController? _webViewController;
  String? _currentUrl;
  String? _loadError;
  bool _reloading = false;

  @override
  void initState() {
    super.initState();
    _currentUrl = widget.article.url;
  }

  Future<void> _openInBrowser() async {
    final uri = Uri.parse(_currentUrl ?? widget.article.url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _reload() async {
    setState(() {
      _loadError = null;
      _reloading = true;
      _progress = 0;
    });
    await _webViewController?.reload();
    if (mounted) setState(() => _reloading = false);
  }

  @override
  Widget build(BuildContext context) {
    final webZoom = ref.watch(webZoomProvider);
    final isLocalImage = widget.article.isLocalImage;
    final isLocalPdf = widget.article.isLocalPdf;
    final isLocalFile = isLocalImage || isLocalPdf;
    final s = ref.watch(stringsProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.article.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          if (!isLocalFile)
            IconButton(
              icon: _reloading
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.refresh),
              onPressed: _reloading ? null : _reload,
              tooltip: 'Refresh',
            ),
          if (!isLocalFile)
            IconButton(
              icon: const Icon(Icons.open_in_browser),
              onPressed: _openInBrowser,
              tooltip: 'Open in browser',
            ),
        ],
      ),
      body: isLocalImage
          ? _LocalImageBody(
              article: widget.article,
              missingLabel: s.imageSourceUnavailable,
            )
          : isLocalPdf
          ? _LocalPdfBody(article: widget.article)
          : Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 960),
                child: Column(
                  children: [
                    if (_progress < 1.0)
                      LinearProgressIndicator(
                        value: _progress,
                        backgroundColor: Colors.grey[200],
                        color: widget.article.source.accentColor,
                      ),
                    Expanded(
                      child: ReaderWebViewSurface(
                        errorOverlay: _loadError == null
                            ? null
                            : Center(
                                child: Padding(
                                  padding: const EdgeInsets.all(32),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Icon(
                                        Icons.cloud_off_rounded,
                                        size: 48,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .error
                                            .withValues(alpha: 0.6),
                                      ),
                                      const SizedBox(height: 16),
                                      Text(
                                        'Failed to load page',
                                        style: Theme.of(
                                          context,
                                        ).textTheme.titleMedium,
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        _loadError!,
                                        textAlign: TextAlign.center,
                                        style: Theme.of(context)
                                            .textTheme
                                            .bodySmall
                                            ?.copyWith(
                                              color: Theme.of(context)
                                                  .colorScheme
                                                  .onSurface
                                                  .withValues(alpha: 0.6),
                                            ),
                                      ),
                                      const SizedBox(height: 16),
                                      OutlinedButton.icon(
                                        onPressed: _reload,
                                        icon: const Icon(
                                          Icons.refresh,
                                          size: 18,
                                        ),
                                        label: const Text('Retry'),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                        webView: InAppWebView(
                          initialUrlRequest: URLRequest(
                            url: WebUri(widget.article.url),
                          ),
                          initialSettings: createReaderWebViewSettings(webZoom),
                          onWebViewCreated: (controller) {
                            _webViewController = controller;
                          },
                          onProgressChanged: (controller, progress) {
                            setState(() {
                              _progress = progress / 100;
                            });
                          },
                          onUpdateVisitedHistory: (controller, uri, isReload) {
                            setState(() {
                              _currentUrl = uri?.toString();
                            });
                          },
                          onReceivedError: (controller, request, error) {
                            if (!shouldTreatWebResourceErrorAsPageFailure(
                              request.isForMainFrame,
                            )) {
                              return;
                            }
                            setState(() {
                              _loadError = error.description;
                            });
                          },
                          shouldOverrideUrlLoading:
                              (controller, navigationAction) async {
                                final uri = navigationAction.request.url;
                                if (uri == null) {
                                  return NavigationActionPolicy.ALLOW;
                                }

                                final scheme = uri.scheme.toLowerCase();

                                // Block WeChat deep links
                                if (scheme == 'weixin' || scheme == 'wechat') {
                                  return NavigationActionPolicy.CANCEL;
                                }

                                // Block other app deep links (tel:, mailto:, etc.)
                                if (![
                                  'http',
                                  'https',
                                  'about',
                                  'javascript',
                                  'data',
                                ].contains(scheme)) {
                                  return NavigationActionPolicy.CANCEL;
                                }

                                // Block common redirect patterns
                                final host = uri.host.toLowerCase();
                                if (host.contains('itunes.apple.com') ||
                                    host.contains('play.google.com') ||
                                    host.contains('apps.apple.com')) {
                                  return NavigationActionPolicy.CANCEL;
                                }

                                return NavigationActionPolicy.ALLOW;
                              },
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
    );
  }
}

class _LocalImageBody extends StatefulWidget {
  final Article article;
  final String missingLabel;
  const _LocalImageBody({required this.article, required this.missingLabel});

  @override
  State<_LocalImageBody> createState() => _LocalImageBodyState();
}

class _LocalImageBodyState extends State<_LocalImageBody> {
  late final Future<List<File?>> _filesFuture;
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    final store = AttachmentStore();
    _filesFuture = Future.wait(
      widget.article.imageAttachments.map(
        (attachment) => store.resolve(attachment.localPath),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<File?>>(
      future: _filesFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final files = snapshot.data ?? const <File?>[];
        if (files.isEmpty) {
          return Center(
            child: Text(
              widget.missingLabel,
              style: Theme.of(context).textTheme.titleMedium,
            ),
          );
        }
        return Stack(
          children: [
            PageView.builder(
              itemCount: files.length,
              onPageChanged: (index) => setState(() => _currentIndex = index),
              itemBuilder: (context, index) {
                final file = files[index];
                if (file == null) {
                  return Center(
                    child: Text(
                      widget.missingLabel,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  );
                }
                return InteractiveViewer(
                  minScale: 0.5,
                  maxScale: 5,
                  child: Center(
                    child: Image.file(
                      file,
                      fit: BoxFit.contain,
                      errorBuilder: (_, _, _) => const Center(
                        child: Icon(Icons.broken_image_outlined, size: 48),
                      ),
                    ),
                  ),
                );
              },
            ),
            if (files.length > 1)
              Positioned(
                right: 16,
                bottom: 16,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.65),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '${_currentIndex + 1}/${files.length}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _LocalPdfBody extends StatefulWidget {
  final Article article;
  const _LocalPdfBody({required this.article});

  @override
  State<_LocalPdfBody> createState() => _LocalPdfBodyState();
}

class _LocalPdfBodyState extends State<_LocalPdfBody> {
  late final Future<File?> _fileFuture;

  @override
  void initState() {
    super.initState();
    _fileFuture = AttachmentStore().resolve(widget.article.localFilePath);
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<File?>(
      future: _fileFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Center(child: CircularProgressIndicator());
        }
        final file = snapshot.data;
        if (file == null) {
          return Center(
            child: Text(
              'PDF file not found',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          );
        }
        return PdfViewer.file(
          file.path,
          params: const PdfViewerParams(margin: 8),
        );
      },
    );
  }
}
