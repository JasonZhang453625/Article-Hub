import 'package:flutter_test/flutter_test.dart';
import 'package:article_hub/shared/utils/date_formatter.dart';

void main() {
  group('formatRelative', () {
    test('returns "just now" for very recent times', () {
      expect(formatRelative(DateTime.now()), 'just now');
      expect(
        formatRelative(DateTime.now().subtract(const Duration(seconds: 30))),
        'just now',
      );
    });

    test('formats minutes, hours and days', () {
      final now = DateTime.now();
      expect(
        formatRelative(now.subtract(const Duration(minutes: 5))),
        '5m ago',
      );
      expect(
        formatRelative(now.subtract(const Duration(hours: 3))),
        '3h ago',
      );
      expect(
        formatRelative(now.subtract(const Duration(days: 2))),
        '2d ago',
      );
    });

    test('falls back to an absolute date beyond a week', () {
      final old = DateTime(2020, 1, 15);
      expect(formatRelative(old), '2020-01-15');
    });

    test('handles future timestamps without negative output (regression)', () {
      // Clock skew can produce a timestamp slightly in the future; it must not
      // render as a negative relative time.
      final future = DateTime.now().add(const Duration(hours: 2));
      expect(formatRelative(future), 'just now');
    });
  });
}
