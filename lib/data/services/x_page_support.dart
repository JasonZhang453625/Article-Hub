import 'package:html/dom.dart';
import 'package:html/parser.dart' as html_parser;

const int xLongArticleMinimumTextLength = 200;
const int xLongArticleSemanticFallbackMinimumTextLength = 300;
const int xLongArticleSemanticFallbackMinimumBlocks = 3;

class XStatusTarget {
  final String statusId;

  const XStatusTarget(this.statusId);

  static XStatusTarget? tryParse(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    final host = uri.host.toLowerCase();
    if (host != 'x.com' &&
        !host.endsWith('.x.com') &&
        host != 'twitter.com' &&
        !host.endsWith('.twitter.com')) {
      return null;
    }

    final segments = uri.pathSegments;
    for (var i = 0; i < segments.length - 1; i++) {
      if (segments[i].toLowerCase() != 'status') continue;
      final statusId = segments[i + 1];
      if (RegExp(r'^\d{1,19}$').hasMatch(statusId)) {
        return XStatusTarget(statusId);
      }
    }
    return null;
  }
}

class XPageAssessment {
  final bool isXStatusPage;
  final bool hasTargetArticle;
  final bool looksLikeLongArticle;
  final bool hasCompleteArticleBody;
  final String? title;
  final String? content;
  final String? embeddedArticleStatusUrl;
  final bool needsRuntimeArticleBody;
  final String reason;

  const XPageAssessment({
    required this.isXStatusPage,
    required this.hasTargetArticle,
    required this.looksLikeLongArticle,
    required this.hasCompleteArticleBody,
    required this.reason,
    this.title,
    this.content,
    this.embeddedArticleStatusUrl,
    this.needsRuntimeArticleBody = false,
  });

  bool get hasExtractableContent =>
      content != null && content!.trim().isNotEmpty;
}

XPageAssessment assessXPage(String htmlBody, String url) {
  final target = XStatusTarget.tryParse(url);
  if (target == null) {
    return const XPageAssessment(
      isXStatusPage: false,
      hasTargetArticle: false,
      looksLikeLongArticle: false,
      hasCompleteArticleBody: false,
      reason: 'not_x_status_page',
    );
  }

  final document = html_parser.parse(htmlBody);
  final article = _findTargetArticle(document, target.statusId);
  if (article == null) {
    final metadataContent = _pageMetadataContent(document);
    return XPageAssessment(
      isXStatusPage: true,
      hasTargetArticle: false,
      looksLikeLongArticle: false,
      hasCompleteArticleBody: false,
      reason: metadataContent == null
          ? 'x_target_article_missing'
          : 'x_page_metadata_fallback',
      content: metadataContent,
    );
  }

  final heading = _cleanInline(article.querySelector('h1')?.text ?? '');
  final explicitBody = article.querySelector('.x-article-body');
  final runtimeBody = _runtimeArticleBody(article);
  final hasCompleteRuntimeBody =
      runtimeBody.length >= xLongArticleMinimumTextLength;
  final structuredBody = _cleanInline(
    article
            .querySelector('meta[itemprop="articleBody"]')
            ?.attributes['content'] ??
        '',
  );
  final hasArticleCover =
      article.querySelector('img[alt="Article cover image"]') != null;
  final embeddedArticleStatusUrl = _embeddedArticleStatusUrl(article);
  final looksLikeLongArticle =
      explicitBody != null ||
      runtimeBody.isNotEmpty ||
      heading.isNotEmpty ||
      hasArticleCover;

  final body = explicitBody ?? article;
  final blocks = _contentBlocks(body, excludeHeading: explicitBody == null);
  final bodyText = blocks.isEmpty
      ? _cleanInline(body.text)
      : blocks.join('\n\n');
  final isExplicitBodyComplete =
      explicitBody != null &&
      bodyText.length >= xLongArticleMinimumTextLength &&
      (blocks.length >= 2 || bodyText.length >= 500);
  final isSemanticFallbackComplete =
      explicitBody == null &&
      heading.isNotEmpty &&
      blocks.length >= xLongArticleSemanticFallbackMinimumBlocks &&
      bodyText.length >= xLongArticleSemanticFallbackMinimumTextLength;
  final needsRuntimeArticleBody =
      looksLikeLongArticle &&
      !hasCompleteRuntimeBody &&
      embeddedArticleStatusUrl == null &&
      !isExplicitBodyComplete &&
      !isSemanticFallbackComplete;

  if (hasCompleteRuntimeBody) {
    return XPageAssessment(
      isXStatusPage: true,
      hasTargetArticle: true,
      looksLikeLongArticle: true,
      hasCompleteArticleBody: true,
      title: heading.isEmpty ? null : heading,
      content: [if (heading.isNotEmpty) heading, runtimeBody].join('\n\n'),
      reason: 'x_runtime_article_body',
    );
  }

  // X's server-rendered `articleBody` belongs to the target post itself. It
  // remains trustworthy even when that post embeds an Article card whose
  // cover image would otherwise make the post look like an incomplete
  // long-form article.
  if (structuredBody.isNotEmpty) {
    return XPageAssessment(
      isXStatusPage: true,
      hasTargetArticle: true,
      looksLikeLongArticle: looksLikeLongArticle,
      hasCompleteArticleBody: false,
      title: heading.isEmpty ? null : heading,
      content: structuredBody,
      embeddedArticleStatusUrl: embeddedArticleStatusUrl,
      needsRuntimeArticleBody: needsRuntimeArticleBody,
      reason: 'x_structured_post_body',
    );
  }

  if (!looksLikeLongArticle) {
    return XPageAssessment(
      isXStatusPage: true,
      hasTargetArticle: true,
      looksLikeLongArticle: false,
      hasCompleteArticleBody: false,
      reason: 'x_normal_post',
      content: bodyText,
      embeddedArticleStatusUrl: embeddedArticleStatusUrl,
    );
  }

  final complete = isExplicitBodyComplete || isSemanticFallbackComplete;

  if (!complete) {
    return XPageAssessment(
      isXStatusPage: true,
      hasTargetArticle: true,
      looksLikeLongArticle: true,
      hasCompleteArticleBody: false,
      title: heading.isEmpty ? null : heading,
      embeddedArticleStatusUrl: embeddedArticleStatusUrl,
      needsRuntimeArticleBody: needsRuntimeArticleBody,
      reason: 'x_long_article_body_missing',
    );
  }

  final content = [
    if (heading.isNotEmpty) heading,
    bodyText,
  ].where((part) => part.trim().isNotEmpty).join('\n\n');
  return XPageAssessment(
    isXStatusPage: true,
    hasTargetArticle: true,
    looksLikeLongArticle: true,
    hasCompleteArticleBody: true,
    title: heading.isEmpty ? null : heading,
    content: content,
    embeddedArticleStatusUrl: embeddedArticleStatusUrl,
    reason: 'x_long_article_complete',
  );
}

class XWebViewReadiness {
  final bool targetFound;
  final bool longArticleHint;
  final bool articleReady;
  final int targetTextLength;
  final int articleTextLength;

  const XWebViewReadiness({
    required this.targetFound,
    required this.longArticleHint,
    required this.articleReady,
    required this.targetTextLength,
    required this.articleTextLength,
  });

  factory XWebViewReadiness.fromSnapshot(Map<dynamic, dynamic> snapshot) {
    return XWebViewReadiness(
      targetFound: snapshot['xTargetFound'] == true,
      longArticleHint: snapshot['xLongArticleHint'] == true,
      articleReady: snapshot['xArticleReady'] == true,
      targetTextLength: _asInt(snapshot['xTargetTextLength']),
      articleTextLength: _asInt(snapshot['xArticleTextLength']),
    );
  }

  bool get hasUsableTarget => longArticleHint ? articleReady : targetFound;

  int get observedTextLength =>
      longArticleHint ? articleTextLength : targetTextLength;
}

Element? _findTargetArticle(Document document, String statusId) {
  final articles = document.querySelectorAll('article');
  for (final article in articles) {
    if (_articleMatchesStatus(article, statusId)) return article;
  }
  for (final article in articles) {
    if (article.querySelector('.x-article-body') != null ||
        article.querySelector('h1') != null) {
      return article;
    }
  }
  return null;
}

bool _articleMatchesStatus(Element article, String statusId) {
  if (article.attributes['data-tweet-id'] == statusId) return true;

  for (final meta in article.querySelectorAll('meta[itemprop]')) {
    final itemProp = meta.attributes['itemprop'];
    final content = meta.attributes['content'];
    if (itemProp == 'identifier' && content == statusId) return true;
    if ((itemProp == 'url' || itemProp == 'mainEntityOfPage') &&
        _urlContainsStatus(content, statusId)) {
      return true;
    }
  }

  return _articleLinksToStatus(article, statusId);
}

bool _articleLinksToStatus(Element article, String statusId) {
  for (final link in article.querySelectorAll('a[href]')) {
    final href = link.attributes['href'];
    if (href == null) continue;
    if (_urlContainsStatus(href, statusId)) return true;
  }
  return false;
}

bool _urlContainsStatus(String? value, String statusId) {
  if (value == null) return false;
  final path = Uri.tryParse(value)?.path ?? value;
  return RegExp('/status/$statusId(?:/|\$)').hasMatch(path);
}

String? _embeddedArticleStatusUrl(Element article) {
  for (final link in article.querySelectorAll('a[href]')) {
    final href = link.attributes['href'];
    if (href == null) continue;
    final segments =
        Uri.tryParse(href)?.pathSegments ??
        Uri.tryParse('https://x.com$href')?.pathSegments;
    if (segments == null || segments.length < 3) continue;
    for (var i = 0; i < segments.length - 2; i++) {
      if (segments[i].toLowerCase() != 'i' ||
          segments[i + 1].toLowerCase() != 'article') {
        continue;
      }
      final articleId = segments[i + 2];
      if (RegExp(r'^\d{1,19}$').hasMatch(articleId)) {
        return 'https://x.com/i/status/$articleId';
      }
    }
  }
  return null;
}

String _runtimeArticleBody(Element article) {
  final candidates = <String>[
    for (final element in article.querySelectorAll(
      '[data-testid="twitterArticleRichTextView"], '
      '[data-testid="longformRichTextComponent"]',
    ))
      _cleanArticleText(element.text),
  ].where((text) => text.isNotEmpty).toList();
  if (candidates.isEmpty) return '';
  candidates.sort((a, b) => b.length.compareTo(a.length));
  return candidates.first;
}

String _cleanArticleText(String text) {
  return text
      .replaceAll('\r\n', '\n')
      .replaceAll(RegExp(r'[ \t]+\n'), '\n')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n')
      .trim();
}

String? _pageMetadataContent(Document document) {
  final candidates = [
    _metaContent(document, 'og:description'),
    _metaContent(document, 'twitter:description'),
    _metaContent(document, 'description'),
  ];
  for (final candidate in candidates) {
    final text = _cleanInline(candidate ?? '');
    if (_isUsableXMetadataText(text)) return text;
  }
  return null;
}

String? _metaContent(Document document, String name) {
  final element =
      document.querySelector('meta[property="$name"]') ??
      document.querySelector('meta[name="$name"]');
  return element?.attributes['content'];
}

bool _isUsableXMetadataText(String text) {
  if (text.length < 20) return false;
  final lower = text.toLowerCase();
  const pageChrome = [
    'log in',
    'sign up',
    'see new posts',
    "what's happening",
    'x. it',
  ];
  return !pageChrome.any(lower.contains);
}

List<String> _contentBlocks(Element root, {required bool excludeHeading}) {
  final values = <String>[];
  for (final element in root.querySelectorAll(
    'h2, h3, h4, p, li, blockquote',
  )) {
    if (excludeHeading && element.localName == 'h1') continue;
    final text = _cleanInline(element.text);
    if (text.isNotEmpty) values.add(text);
  }
  return values;
}

String _cleanInline(String text) {
  return text.replaceAll(RegExp(r'\s+'), ' ').trim();
}

int _asInt(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return 0;
}
