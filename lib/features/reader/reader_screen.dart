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

/// A failed image, iframe, ad, or analytics request must not replace an
/// otherwise healthy page with the full-page error state.
bool shouldTreatWebResourceErrorAsPageFailure(bool? isForMainFrame) {
  return isForMainFrame == true;
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
          ? _LocalImageBody(article: widget.article)
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
            child: _loadError != null
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.cloud_off_rounded,
                              size: 48,
                              color: Theme.of(context)
                                  .colorScheme
                                  .error
                                  .withValues(alpha: 0.6)),
                          const SizedBox(height: 16),
                          Text(
                            'Failed to load page',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium,
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
                            icon: const Icon(Icons.refresh, size: 18),
                            label: const Text('Retry'),
                          ),
                        ],
                      ),
                    ),
                  )
                : InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.article.url)),
              initialSettings: InAppWebViewSettings(
                userAgent: articleHubMobileUserAgent,
                javaScriptEnabled: true,
                supportZoom: true,
                useWideViewPort: true,
                builtInZoomControls: true,
                displayZoomControls: false,
                allowsInlineMediaPlayback: true,
                mediaPlaybackRequiresUserGesture: false,
                textZoom: webZoom,
              ),
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
              shouldOverrideUrlLoading: (controller, navigationAction) async {
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
        ],
      ),
      ),
      ),
    );
  }
}

class _LocalImageBody extends StatefulWidget {
  final Article article;
  const _LocalImageBody({required this.article});

  @override
  State<_LocalImageBody> createState() => _LocalImageBodyState();
}

class _LocalImageBodyState extends State<_LocalImageBody> {
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
              'Image file not found',
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
              errorBuilder: (_, e, s) => const Center(
                child: Icon(Icons.broken_image_outlined, size: 48),
              ),
            ),
          ),
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
          params: const PdfViewerParams(
            margin: 8,
          ),
        );
      },
    );
  }
}
