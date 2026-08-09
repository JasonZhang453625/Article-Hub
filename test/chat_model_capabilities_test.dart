import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/services/chat_model_capabilities.dart';

void main() {
  test('recognizes common native vision chat models conservatively', () {
    expect(chatModelSupportsImageInput('gpt-4o-mini'), isTrue);
    expect(chatModelSupportsImageInput('mimo-v2.5'), isTrue);
    expect(chatModelSupportsImageInput('mimo-v2.5-pro'), isFalse);
    expect(chatModelSupportsImageInput('deepseek-chat'), isFalse);
  });

  test('provider-declared vision capability overrides name heuristics', () {
    expect(
      chatModelSupportsImageInput(
        'company/custom-chat',
        declaredVisionModels: const ['company/custom-chat'],
      ),
      isTrue,
    );
  });

  test('server declarations are authoritative for hosted models', () {
    expect(
      chatModelSupportsImageInput(
        'mimo-v2.5-pro',
        declaredVisionModels: const ['mimo-v2.5'],
      ),
      isFalse,
    );
  });
}
