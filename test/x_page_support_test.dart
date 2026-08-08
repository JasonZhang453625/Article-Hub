import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/services/x_page_support.dart';

void main() {
  group('XStatusTarget', () {
    test('accepts both canonical and i/status URLs', () {
      expect(
        XStatusTarget.tryParse(
          'https://x.com/author/status/2048757569775378858',
        )?.statusId,
        '2048757569775378858',
      );
      expect(
        XStatusTarget.tryParse(
          'https://x.com/i/status/2048757569775378858',
        )?.statusId,
        '2048757569775378858',
      );
      expect(XStatusTarget.tryParse('https://example.com/status/123'), isNull);
    });
  });

  group('assessXPage', () {
    test('extracts only the complete long-article body', () {
      final assessment = assessXPage(
        _completeXArticleHtml,
        'https://x.com/author/status/2048757569775378858',
      );

      expect(assessment.looksLikeLongArticle, isTrue);
      expect(assessment.hasCompleteArticleBody, isTrue);
      expect(assessment.title, 'A complete X article');
      expect(assessment.content, contains('Opening evidence'));
      expect(assessment.content, contains('Middle evidence'));
      expect(assessment.content, contains('Closing evidence'));
      expect(assessment.content, isNot(contains('Log in to X')));
      expect(assessment.content, isNot(contains('Reply noise')));
    });

    test(
      'rejects a logged-out long-article preview even when page is long',
      () {
        final assessment = assessXPage(
          _loggedOutXArticlePreviewHtml,
          'https://x.com/i/status/2048757569775378858',
        );

        expect(assessment.looksLikeLongArticle, isTrue);
        expect(assessment.hasCompleteArticleBody, isFalse);
        expect(assessment.content, isNull);
        expect(assessment.reason, 'x_long_article_body_missing');
      },
    );

    test('does not classify a normal X post as a long article', () {
      final assessment = assessXPage(
        _normalXPostHtml,
        'https://x.com/author/status/1234567890',
      );

      expect(assessment.looksLikeLongArticle, isFalse);
      expect(assessment.hasCompleteArticleBody, isFalse);
    });

    test('recognizes current X server-rendered target metadata', () {
      final assessment = assessXPage(
        _currentXLongArticleHtml,
        'https://x.com/author/status/2048757569775378858',
      );

      expect(assessment.hasTargetArticle, isTrue);
      expect(assessment.hasCompleteArticleBody, isTrue);
      expect(assessment.content, contains('Opening structured evidence'));
    });

    test('does not accept an X login shell without the target post', () {
      final assessment = assessXPage(
        '<html><body><main>Log in to see posts and conversations. '
            'Trending recommendations account controls and navigation.</main>'
            '</body></html>',
        'https://x.com/i/status/2048757569775378858',
      );

      expect(assessment.hasTargetArticle, isFalse);
      expect(assessment.reason, 'x_target_article_missing');
    });
  });

  group('XWebViewReadiness', () {
    test('does not accept a stable login shell or article preview', () {
      expect(
        XWebViewReadiness.fromSnapshot(const {
          'xTargetFound': false,
          'xLongArticleHint': false,
          'xArticleReady': false,
          'xTargetTextLength': 1200,
          'xArticleTextLength': 0,
        }).hasUsableTarget,
        isFalse,
      );
      expect(
        XWebViewReadiness.fromSnapshot(const {
          'xTargetFound': true,
          'xLongArticleHint': true,
          'xArticleReady': false,
          'xTargetTextLength': 320,
          'xArticleTextLength': 0,
        }).hasUsableTarget,
        isFalse,
      );
    });

    test('accepts complete long articles and normal target posts', () {
      final article = XWebViewReadiness.fromSnapshot(const {
        'xTargetFound': true,
        'xLongArticleHint': true,
        'xArticleReady': true,
        'xTargetTextLength': 5200,
        'xArticleTextLength': 4900,
      });
      final post = XWebViewReadiness.fromSnapshot(const {
        'xTargetFound': true,
        'xLongArticleHint': false,
        'xArticleReady': false,
        'xTargetTextLength': 80,
        'xArticleTextLength': 0,
      });

      expect(article.hasUsableTarget, isTrue);
      expect(article.observedTextLength, 4900);
      expect(post.hasUsableTarget, isTrue);
      expect(post.observedTextLength, 80);
    });
  });
}

const _completeXArticleHtml =
    '''
<html>
  <body>
    <aside>Log in to X $_longNoise</aside>
    <main>
      <article>
        <a href="/author/status/2048757569775378858">Permalink</a>
        <h1>A complete X article</h1>
        <div class="x-article-body">
          <p>Opening evidence $_substantiveText</p>
          <p>Middle evidence $_substantiveText</p>
          <p>Closing evidence $_substantiveText</p>
        </div>
      </article>
      <article>
        <a href="/reply/status/999">Reply</a>
        <p>Reply noise $_longNoise</p>
      </article>
    </main>
  </body>
</html>
''';

const _loggedOutXArticlePreviewHtml =
    '''
<html>
  <body>
    <main>
      <article>
        <a href="/author/status/2048757569775378858">Permalink</a>
        <img alt="Article cover image" src="cover.jpg">
        <h1>A complete X article</h1>
        <p>Only a short preview is visible while logged out.</p>
      </article>
    </main>
    <aside>Log in or sign up for X $_longNoise$_longNoise</aside>
  </body>
</html>
''';

const _normalXPostHtml = '''
<html><body><main><article>
  <a href="/author/status/1234567890">Permalink</a>
  <p>This is an ordinary short X post.</p>
</article></main></body></html>
''';

const _currentXLongArticleHtml =
    '''
<html><body><article data-tweet-id="2048757569775378858"
  itemid="https://x.com/i/status/2048757569775378858">
  <meta content="2048757569775378858" itemprop="identifier">
  <meta content="https://x.com/author/status/2048757569775378858"
    itemprop="mainEntityOfPage">
  <meta itemprop="articleBody" content="Opening structured evidence
    $_substantiveText $_substantiveText $_substantiveText">
  <div>Opening structured evidence</div>
</article></body></html>
''';

const _substantiveText =
    'contains enough meaningful source material for extraction validation and '
    'must remain separate from surrounding page controls and replies.';

const _longNoise =
    'navigation recommendations trending conversations account controls '
    'repeated page chrome that is long enough to fool a generic length check. ';
