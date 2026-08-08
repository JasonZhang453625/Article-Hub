import 'package:flutter_test/flutter_test.dart';

import 'package:memora/shared/utils/ai_error_messages.dart';
import 'package:memora/shared/utils/locale_strings.dart';

void main() {
  test('connection abort is translated into a useful Chinese message', () {
    final message = localizedAiErrorMessage(
      LocaleStrings.of(1),
      'AI request failed: ClientException: Software caused connection abort, '
      'uri=https://api.example.com/chat',
    );

    expect(message, contains('网络连接'));
    expect(message, contains('重试'));
    expect(message, isNot(contains('ClientException')));
    expect(message, isNot(contains('api.example.com')));
  });

  test('maps common provider failures without exposing raw details', () {
    final strings = LocaleStrings.of(1);

    expect(
      localizedAiErrorMessage(strings, 'AI request timed out'),
      contains('响应时间'),
    );
    expect(
      localizedAiErrorMessage(strings, 'HTTP 401: invalid token'),
      contains('认证失败'),
    );
    expect(
      localizedAiErrorMessage(strings, 'HTTP 503: overloaded'),
      contains('暂时繁忙'),
    );
    expect(
      localizedAiErrorMessage(strings, 'HTTP 429: quota exceeded'),
      contains('限制'),
    );
  });

  test('keeps the same error categories localized in English', () {
    final message = localizedAiErrorMessage(
      LocaleStrings.of(2),
      'Software caused connection abort',
    );

    expect(message, contains('network connection'));
    expect(message, contains('Retry'));
  });
}
