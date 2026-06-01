import 'package:flutter_test/flutter_test.dart';
import 'package:article_hub/shared/utils/url_helpers.dart';

void main() {
  group('cleanUrl', () {
    test('adds https scheme when missing', () {
      expect(cleanUrl('example.com/article'), 'https://example.com/article');
    });

    test('preserves existing http and https schemes', () {
      expect(cleanUrl('http://example.com'), 'http://example.com');
      expect(cleanUrl('https://example.com'), 'https://example.com');
    });

    test('trims surrounding whitespace', () {
      expect(cleanUrl('  example.com  '), 'https://example.com');
    });

    test('returns empty string unchanged', () {
      expect(cleanUrl(''), '');
      expect(cleanUrl('   '), '');
    });
  });

  group('isValidUrl', () {
    test('accepts http and https URLs with a host', () {
      expect(isValidUrl('https://example.com'), isTrue);
      expect(isValidUrl('http://example.com/path'), isTrue);
    });

    test('rejects URLs without a host', () {
      expect(isValidUrl('https://'), isFalse);
    });

    test('rejects non-http schemes', () {
      expect(isValidUrl('ftp://example.com'), isFalse);
      expect(isValidUrl('mailto:user@example.com'), isFalse);
    });

    test('rejects malformed input', () {
      expect(isValidUrl('not a url'), isFalse);
      expect(isValidUrl(''), isFalse);
    });
  });

  group('extractDomain', () {
    test('returns the host for valid URLs', () {
      expect(extractDomain('https://www.example.com/path'), 'www.example.com');
    });

    test('returns empty host for schemeless input', () {
      // Uri.tryParse('example.com') parses with an empty host.
      expect(extractDomain('example.com'), '');
    });
  });

  group('parseUrlList', () {
    test('splits on newlines, spaces, commas and semicolons', () {
      final result = parseUrlList(
        'https://x.com/a\nhttps://b.com/b, https://c.com/c;https://d.com/d',
      );
      expect(result, [
        'https://x.com/a',
        'https://b.com/b',
        'https://c.com/c',
        'https://d.com/d',
      ]);
    });

    test('adds missing scheme and drops invalid candidates', () {
      final result = parseUrlList('example.com\nnot a url\nhttps://valid.com');
      expect(result, ['https://example.com', 'https://valid.com']);
    });

    test('de-duplicates while preserving first-seen order', () {
      final result = parseUrlList(
        'https://x.com/a\nhttps://x.com/a\nhttps://y.com',
      );
      expect(result, ['https://x.com/a', 'https://y.com']);
    });

    test('returns empty list for blank input', () {
      expect(parseUrlList(''), isEmpty);
      expect(parseUrlList('   \n  \t '), isEmpty);
    });
  });
}
