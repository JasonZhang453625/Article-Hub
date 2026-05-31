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
}
