import 'package:flutter_test/flutter_test.dart';
import 'package:memora/shared/providers/settings_providers.dart';

void main() {
  test('chat follow-language prompt refers to the current question', () {
    expect(aiChatLanguagePrompt(0), contains("user's current question"));
    expect(aiChatLanguagePrompt(0), isNot(contains('article title')));
  });

  test('chat explicit language choices match article processing choices', () {
    expect(aiChatLanguagePrompt(1), aiLanguagePrompt(1));
    expect(aiChatLanguagePrompt(2), aiLanguagePrompt(2));
  });
}
