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
  final String reason;

  const XPageAssessment({
    required this.isXStatusPage,
    required this.hasTargetArticle,
    required this.looksLikeLongArticle,
    required this.hasCompleteArticleBody,
    required this.reason,
    this.title,
    this.content,
  });
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
    return const XPageAssessment(
      isXStatusPage: true,
      hasTargetArticle: false,
      looksLikeLongArticle: false,
      hasCompleteArticleBody: false,
      reason: 'x_target_article_missing',
    );
  }

  final heading = _cleanInline(article.querySelector('h1')?.text ?? '');
  final explicitBody = article.querySelector('.x-article-body');
  final hasArticleCover =
      article.querySelector('img[alt="Article cover image"]') != null;
  final looksLikeLongArticle =
      explicitBody != null || heading.isNotEmpty || hasArticleCover;

  if (!looksLikeLongArticle) {
    return const XPageAssessment(
      isXStatusPage: true,
      hasTargetArticle: true,
      looksLikeLongArticle: false,
      hasCompleteArticleBody: false,
      reason: 'x_normal_post',
    );
  }

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
  final complete = isExplicitBodyComplete || isSemanticFallbackComplete;

  if (!complete) {
    return XPageAssessment(
      isXStatusPage: true,
      hasTargetArticle: true,
      looksLikeLongArticle: true,
      hasCompleteArticleBody: false,
      title: heading.isEmpty ? null : heading,
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
    if (_articleLinksToStatus(article, statusId)) return article;
  }
  for (final article in articles) {
    if (article.querySelector('.x-article-body') != null ||
        article.querySelector('h1') != null) {
      return article;
    }
  }
  return null;
}

bool _articleLinksToStatus(Element article, String statusId) {
  for (final link in article.querySelectorAll('a[href]')) {
    final href = link.attributes['href'];
    if (href == null) continue;
    final path = Uri.tryParse(href)?.path ?? href;
    if (RegExp('/status/$statusId(?:/|\$)').hasMatch(path)) return true;
  }
  return false;
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
