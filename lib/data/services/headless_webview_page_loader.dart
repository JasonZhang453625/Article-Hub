import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'page_loader.dart';

const articleHubMobileUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/120.0.0.0 Mobile Safari/537.36';

final SerialPageLoadCoordinator _headlessWebViewCoordinator =
    SerialPageLoadCoordinator();

class HeadlessWebViewPageLoader implements PageLoader {
  final Duration timeout;
  final Duration domWait;
  final Duration pollInterval;
  final SerialPageLoadCoordinator coordinator;

  HeadlessWebViewPageLoader({
    this.timeout = const Duration(seconds: 20),
    this.domWait = const Duration(seconds: 5),
    this.pollInterval = const Duration(milliseconds: 500),
    SerialPageLoadCoordinator? coordinator,
  }) : coordinator = coordinator ?? _headlessWebViewCoordinator;

  @override
  Future<FetchedPage?> fetch(String url) {
    return coordinator.run(() => _fetchExclusive(url));
  }

  Future<FetchedPage?> _fetchExclusive(String url) async {
    final totalDeadline = DateTime.now().add(timeout);
    final loadFinished = Completer<void>();
    String? mainFrameError;
    HeadlessInAppWebView? webView;

    void finishLoad() {
      if (!loadFinished.isCompleted) loadFinished.complete();
    }

    try {
      webView = HeadlessInAppWebView(
        initialSize: const Size(1024, 768),
        initialUrlRequest: URLRequest(url: WebUri(url)),
        initialSettings: InAppWebViewSettings(
          userAgent: articleHubMobileUserAgent,
          javaScriptEnabled: true,
          domStorageEnabled: true,
          cacheEnabled: true,
          useShouldOverrideUrlLoading: true,
          supportZoom: false,
          mediaPlaybackRequiresUserGesture: true,
        ),
        shouldOverrideUrlLoading: (controller, navigationAction) async {
          final uri = navigationAction.request.url;
          if (uri == null) return NavigationActionPolicy.CANCEL;
          final scheme = uri.scheme.toLowerCase();
          return const {'http', 'https', 'about', 'data'}.contains(scheme)
              ? NavigationActionPolicy.ALLOW
              : NavigationActionPolicy.CANCEL;
        },
        onLoadStop: (controller, uri) => finishLoad(),
        onReceivedHttpError: (controller, request, response) {
          if (request.isForMainFrame == true &&
              (response.statusCode ?? 0) >= 400) {
            mainFrameError = 'HTTP ${response.statusCode}';
            finishLoad();
          }
        },
        onReceivedError: (controller, request, error) {
          if (request.isForMainFrame == true) {
            mainFrameError = error.description;
            finishLoad();
          }
        },
      );

      await webView.run();
      await loadFinished.future.timeout(
        totalDeadline.difference(DateTime.now()),
      );

      if (mainFrameError != null) {
        developer.log(
          'background WebView main document failed: $mainFrameError, url: $url',
          name: 'memora.webview',
        );
        return null;
      }

      final controller = webView.webViewController;
      if (controller == null) {
        developer.log(
          'background WebView controller unavailable, url: $url',
          name: 'memora.webview',
        );
        return null;
      }
      final domDeadline = DateTime.now().add(domWait);
      final deadline = domDeadline.isBefore(totalDeadline)
          ? domDeadline
          : totalDeadline;
      int? previousLength;
      var stableReadings = 0;
      Map<String, dynamic>? snapshot;

      while (DateTime.now().isBefore(deadline)) {
        final raw = await controller.evaluateJavascript(
          source: '''
          (() => {
            const text = (document.body?.innerText || '').trim();
            return {
              title: document.title || '',
              textLength: text.length,
              textSample: text.slice(0, 2000),
              readyState: document.readyState
            };
          })()
        ''',
        );
        if (raw is Map) {
          snapshot = Map<String, dynamic>.from(raw);
          final length = snapshot['textLength'] as int? ?? 0;
          final title = snapshot['title'] as String? ?? '';
          final sample = snapshot['textSample'] as String? ?? '';
          if (looksLikeBlockedPage(title, sample)) {
            developer.log(
              'background WebView reached a blocked/verification page, url: $url',
              name: 'memora.webview',
            );
            return null;
          }

          if (length >= 100 &&
              previousLength != null &&
              (length - previousLength).abs() <= 20) {
            stableReadings++;
          } else {
            stableReadings = 0;
          }
          previousLength = length;
          if (stableReadings >= 2) break;
        }
        await Future<void>.delayed(pollInterval);
      }

      final textLength = snapshot?['textLength'] as int? ?? 0;
      if (textLength < 100) {
        developer.log(
          'background WebView body too short: $textLength chars, url: $url',
          name: 'memora.webview',
        );
        return null;
      }

      final html = await controller.evaluateJavascript(
        source: 'document.documentElement?.outerHTML || ""',
      );
      if (html is! String || html.length < 200) {
        developer.log(
          'background WebView returned empty HTML, url: $url',
          name: 'memora.webview',
        );
        return null;
      }

      final finalUrl = (await controller.getUrl())?.toString() ?? url;
      developer.log(
        'background WebView loaded ${html.length} HTML chars, finalUrl: $finalUrl',
        name: 'memora.webview',
      );
      return FetchedPage(
        statusCode: 200,
        contentType: 'text/html; charset=utf-8',
        body: html,
        finalUrl: finalUrl,
        source: PageLoadSource.webView,
      );
    } on TimeoutException {
      developer.log(
        'background WebView timeout ($timeout), url: $url',
        name: 'memora.webview',
      );
      return null;
    } catch (error, stackTrace) {
      developer.log(
        'background WebView error, url: $url',
        name: 'memora.webview',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    } finally {
      try {
        if (webView != null) {
          await webView.dispose();
          developer.log(
            'background WebView disposed, url: $url',
            name: 'memora.webview',
          );
        }
      } catch (error, stackTrace) {
        developer.log(
          'background WebView dispose failed, url: $url',
          name: 'memora.webview',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }

  @override
  void dispose() {}
}
