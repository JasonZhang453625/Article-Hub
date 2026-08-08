import 'dart:async';
import 'dart:developer' as developer;
import 'dart:ui';

import 'package:flutter_inappwebview/flutter_inappwebview.dart';

import 'page_loader.dart';
import 'x_page_support.dart';

const articleHubMobileUserAgent =
    'Mozilla/5.0 (Linux; Android 14; Pixel 8) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/120.0.0.0 Mobile Safari/537.36';

final SerialPageLoadCoordinator _headlessWebViewCoordinator =
    SerialPageLoadCoordinator();

class HeadlessWebViewPageLoader implements PageLoader {
  static const Duration _cleanupTimeout = Duration(seconds: 2);
  static const Duration _watchdogGrace = Duration(seconds: 1);

  final Duration timeout;
  final Duration domWait;
  final Duration xDomWait;
  final Duration pollInterval;
  final SerialPageLoadCoordinator coordinator;

  HeadlessWebViewPageLoader({
    this.timeout = const Duration(seconds: 20),
    this.domWait = const Duration(seconds: 5),
    this.xDomWait = const Duration(seconds: 10),
    this.pollInterval = const Duration(milliseconds: 500),
    SerialPageLoadCoordinator? coordinator,
  }) : coordinator = coordinator ?? _headlessWebViewCoordinator;

  @override
  Future<FetchedPage?> fetch(String url) async {
    try {
      return await coordinator.run(
        () => _fetchExclusive(url),
        timeout: timeout + _cleanupTimeout + _watchdogGrace,
      );
    } on TimeoutException {
      developer.log(
        'background WebView total timeout ($timeout), url: $url',
        name: 'memora.webview',
      );
      return null;
    }
  }

  Future<FetchedPage?> _fetchExclusive(String url) async {
    final totalDeadline = DateTime.now().add(timeout);
    final loadFinished = Completer<void>();
    String? mainFrameError;
    HeadlessInAppWebView? webView;

    Duration remainingTime() {
      final remaining = totalDeadline.difference(DateTime.now());
      if (remaining <= Duration.zero) {
        throw TimeoutException('Background WebView deadline exceeded');
      }
      return remaining;
    }

    Future<T> beforeDeadline<T>(Future<T> future) {
      return future.timeout(remainingTime());
    }

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

      await beforeDeadline(webView.run());
      await beforeDeadline(loadFinished.future);

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
      final xTarget = XStatusTarget.tryParse(url);
      final effectiveDomWait = xTarget == null ? domWait : xDomWait;
      final domStartedAt = DateTime.now();
      final domDeadline = domStartedAt.add(effectiveDomWait);
      final deadline = domDeadline.isBefore(totalDeadline)
          ? domDeadline
          : totalDeadline;
      int? previousLength;
      var stableReadings = 0;
      Map<String, dynamic>? snapshot;
      XWebViewReadiness? xReadiness;

      while (DateTime.now().isBefore(deadline)) {
        final raw = await beforeDeadline(
          controller.evaluateJavascript(source: _pageSnapshotScript(xTarget)),
        );
        if (raw is Map) {
          snapshot = Map<String, dynamic>.from(raw);
          final title = snapshot['title'] as String? ?? '';
          final sample = snapshot['textSample'] as String? ?? '';
          if (looksLikeBlockedPage(title, sample)) {
            developer.log(
              'background WebView reached a blocked/verification page, url: $url',
              name: 'memora.webview',
            );
            return null;
          }

          var length = snapshot['textLength'] as int? ?? 0;
          var canStabilize = length >= 100;
          if (xTarget != null) {
            xReadiness = XWebViewReadiness.fromSnapshot(snapshot);
            length = xReadiness.observedTextLength;
            canStabilize = xReadiness.hasUsableTarget;

            // A normal X post can appear before X finishes deciding whether
            // the target opens into a long-form article. Give X a short grace
            // period before accepting the normal-post path. Long articles are
            // accepted as soon as their dedicated body is ready and stable.
            final normalPostGraceElapsed =
                DateTime.now().difference(domStartedAt) >=
                const Duration(seconds: 3);
            if (!xReadiness.longArticleHint && !normalPostGraceElapsed) {
              canStabilize = false;
            }
          }

          if (canStabilize &&
              previousLength != null &&
              (length - previousLength).abs() <= 20) {
            stableReadings++;
          } else {
            stableReadings = 0;
          }
          previousLength = canStabilize ? length : null;
          if (stableReadings >= 2) break;
        }
        await Future<void>.delayed(pollInterval);
      }

      final textLength = snapshot?['textLength'] as int? ?? 0;
      if (xTarget != null &&
          (xReadiness == null || !xReadiness.hasUsableTarget)) {
        developer.log(
          'background WebView X target article did not become ready, url: $url',
          name: 'memora.webview',
        );
        return null;
      }
      if (textLength < 100) {
        developer.log(
          'background WebView body too short: $textLength chars, url: $url',
          name: 'memora.webview',
        );
        return null;
      }

      final html = await beforeDeadline(
        controller.evaluateJavascript(
          source: 'document.documentElement?.outerHTML || ""',
        ),
      );
      if (html is! String || html.length < 200) {
        developer.log(
          'background WebView returned empty HTML, url: $url',
          name: 'memora.webview',
        );
        return null;
      }

      final finalUrl =
          (await beforeDeadline(controller.getUrl()))?.toString() ?? url;
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
          await webView.dispose().timeout(_cleanupTimeout);
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

String _pageSnapshotScript(XStatusTarget? xTarget) {
  if (xTarget == null) {
    return '''
      (() => {
        const text = (document.body?.innerText || '').trim();
        return {
          title: document.title || '',
          textLength: text.length,
          textSample: text.slice(0, 2000),
          readyState: document.readyState
        };
      })()
    ''';
  }

  final statusId = xTarget.statusId;
  return '''
    (() => {
      const statusId = '$statusId';
      const pageText = (document.body?.innerText || '').trim();
      const articles = Array.from(document.querySelectorAll('article'));
      const linksToTarget = (article) =>
        Array.from(article.querySelectorAll('a[href]')).some((link) => {
          const href = link.getAttribute('href') || '';
          try {
            const path = new URL(href, location.href).pathname;
            const marker = '/status/' + statusId;
            return path.endsWith(marker) || path.includes(marker + '/');
          } catch (_) {
            return false;
          }
        });
      const target = articles.find(linksToTarget) ||
        articles.find((article) =>
          article.querySelector('.x-article-body') ||
          article.querySelector('h1')) || null;
      const explicitBody = target?.querySelector('.x-article-body') || null;
      const heading = (target?.querySelector('h1')?.innerText || '').trim();
      const hasCover = !!target?.querySelector('img[alt="Article cover image"]');
      const root = explicitBody || target;
      const blocks = root
        ? Array.from(root.querySelectorAll('h2, h3, h4, p, li, blockquote'))
            .map((element) => (element.innerText || '').trim())
            .filter(Boolean)
        : [];
      const articleText = explicitBody
        ? (explicitBody.innerText || '').trim()
        : blocks.join('\\n\\n').trim();
      const longArticleHint = !!explicitBody || !!heading || hasCover;
      const explicitReady = !!explicitBody &&
        articleText.length >= $xLongArticleMinimumTextLength &&
        (blocks.length >= 2 || articleText.length >= 500);
      const semanticReady = !explicitBody && !!heading &&
        blocks.length >= $xLongArticleSemanticFallbackMinimumBlocks &&
        articleText.length >= $xLongArticleSemanticFallbackMinimumTextLength;
      return {
        title: document.title || '',
        textLength: pageText.length,
        textSample: pageText.slice(0, 2000),
        readyState: document.readyState,
        xTargetFound: !!target,
        xLongArticleHint: longArticleHint,
        xArticleReady: explicitReady || semanticReady,
        xTargetTextLength: (target?.innerText || '').trim().length,
        xArticleTextLength: articleText.length,
        xArticleBlockCount: blocks.length
      };
    })()
  ''';
}
