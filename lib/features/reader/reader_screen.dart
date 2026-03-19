import 'package:flutter/material.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../data/models/passage.dart';

class ReaderScreen extends StatefulWidget {
  final Article article;

  const ReaderScreen({super.key, required this.article});

  @override
  State<ReaderScreen> createState() => _ReaderScreenState();
}

class _ReaderScreenState extends State<ReaderScreen> {
  double _progress = 0;
  InAppWebViewController? _webViewController;
  String? _currentUrl;

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.article.title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              _webViewController?.reload();
            },
            tooltip: 'Refresh',
          ),
          IconButton(
            icon: const Icon(Icons.open_in_browser),
            onPressed: _openInBrowser,
            tooltip: 'Open in browser',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_progress < 1.0)
            LinearProgressIndicator(
              value: _progress,
              backgroundColor: Colors.grey[200],
              color: widget.article.source.accentColor,
            ),
          Expanded(
            child: InAppWebView(
              initialUrlRequest: URLRequest(url: WebUri(widget.article.url)),
              initialSettings: InAppWebViewSettings(
                userAgent:
                    'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36',
                javaScriptEnabled: true,
                supportZoom: true,
                useWideViewPort: true,
                builtInZoomControls: true,
                displayZoomControls: false,
                allowsInlineMediaPlayback: true,
                mediaPlaybackRequiresUserGesture: false,
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
    );
  }
}
