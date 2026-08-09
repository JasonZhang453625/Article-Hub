import 'dart:async';
import 'dart:developer' as developer;

import 'package:html/parser.dart' as html_parser;

import 'x_page_support.dart';

enum PageLoadSource { http, webView }

class FetchedPage {
  final int statusCode;
  final String? contentType;
  final String body;
  final String finalUrl;
  final PageLoadSource source;

  const FetchedPage({
    required this.statusCode,
    required this.body,
    required this.finalUrl,
    required this.source,
    this.contentType,
  });

  bool get isHtml =>
      contentType == null || contentType!.toLowerCase().contains('html');
}

abstract interface class PageLoader {
  Future<FetchedPage?> fetch(String url);

  void dispose();
}

bool looksLikeBlockedPage(String title, String bodyText) {
  final sample =
      '$title\n${bodyText.substring(0, bodyText.length.clamp(0, 2000))}'
          .toLowerCase();
  const blockedMarkers = [
    'captcha',
    'verify you are human',
    'access denied',
    '403 forbidden',
    '安全验证',
    '访问异常',
    '请输入验证码',
    '请完成验证',
    '请求过于频繁',
    '操作过于频繁',
    '登录后继续',
  ];
  return blockedMarkers.any(sample.contains);
}

bool fetchedPageLooksBlocked(FetchedPage page) {
  if (!page.isHtml) return false;
  final document = html_parser.parse(page.body);
  return looksLikeBlockedPage(
    document.querySelector('title')?.text.trim() ?? '',
    document.body?.text.trim() ?? '',
  );
}

bool fetchedPageHasUsableDocument(
  FetchedPage page, {
  int minimumTextLength = 100,
}) {
  if (!page.isHtml) return false;
  final document = html_parser.parse(page.body);
  final title = document.querySelector('title')?.text.trim() ?? '';
  final bodyText = document.body?.text.trim() ?? '';
  return !looksLikeBlockedPage(title, bodyText) &&
      bodyText.length >= minimumTextLength;
}

bool fetchedPageHasUsableContentForUrl(FetchedPage page, String requestedUrl) {
  if (!page.isHtml || fetchedPageLooksBlocked(page)) return false;

  final finalUrlTarget = XStatusTarget.tryParse(page.finalUrl);
  final target = finalUrlTarget ?? XStatusTarget.tryParse(requestedUrl);
  if (target == null) return fetchedPageHasUsableDocument(page);

  final assessment = assessXPage(
    page.body,
    finalUrlTarget == null ? requestedUrl : page.finalUrl,
  );
  return assessment.hasExtractableContent;
}

class ResilientPageLoader implements PageLoader {
  final PageLoader primary;
  final PageLoader fallback;
  final bool ownsLoaders;

  ResilientPageLoader({
    required this.primary,
    required this.fallback,
    this.ownsLoaders = true,
  });

  @override
  Future<FetchedPage?> fetch(String url) async {
    final direct = await primary.fetch(url);
    if (direct != null && fetchedPageHasUsableContentForUrl(direct, url)) {
      return direct;
    }

    if (direct != null) {
      developer.log(
        'direct HTTP returned unusable HTML; starting background WebView, '
        'url: $url',
        name: 'memora.page_loader',
      );
    } else {
      developer.log(
        'direct HTTP failed; starting background WebView fallback, url: $url',
        name: 'memora.page_loader',
      );
    }

    final recovered = await fallback.fetch(url);
    if (recovered != null &&
        fetchedPageHasUsableContentForUrl(recovered, url)) {
      return recovered;
    }

    // X changes its DOM frequently. A successfully loaded original document
    // is still useful for metadata and later extractor fallbacks, even when
    // neither source matches the current X-specific content candidates.
    if (direct != null && fetchedPageHasUsableDocument(direct)) {
      developer.log(
        'returning loadable original HTML after X candidate fallback failed, '
        'url: $url',
        name: 'memora.page_loader',
      );
      return direct;
    }
    if (recovered != null && fetchedPageHasUsableDocument(recovered)) {
      developer.log(
        'returning loadable WebView HTML without a preferred content candidate, '
        'url: $url',
        name: 'memora.page_loader',
      );
      return recovered;
    }

    developer.log(
      'HTTP and background WebView both failed, url: $url',
      name: 'memora.page_loader',
    );
    return null;
  }

  @override
  void dispose() {
    if (!ownsLoaders) return;
    primary.dispose();
    fallback.dispose();
  }
}

class SerialPageLoadCoordinator {
  Future<void> _tail = Future<void>.value();

  Future<T> run<T>(Future<T> Function() operation, {Duration? timeout}) {
    final result = Completer<T>();
    final previous = _tail;
    _tail = previous.catchError((_) {}).then((_) async {
      try {
        final operationFuture = operation();
        result.complete(
          await (timeout == null
              ? operationFuture
              : operationFuture.timeout(timeout)),
        );
      } catch (error, stackTrace) {
        result.completeError(error, stackTrace);
      }
    });
    return result.future;
  }
}
