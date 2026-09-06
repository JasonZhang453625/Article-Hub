import 'package:flutter_test/flutter_test.dart';
import 'package:memora/shared/utils/locale_strings.dart';
import 'package:memora/shared/utils/skill_descriptions.dart';

void main() {
  test('localizes every currently exposed Skill description', () {
    final zh = LocaleStrings.of(1);
    for (final name in ['office', 'memora-assistant', 'web-research']) {
      final description = localizedSkillDescription(
        zh,
        name: name,
        description: 'English server description',
      );
      expect(description, isNot(contains('English server description')));
      expect(description, matches(RegExp(r'[\u3400-\u9fff]')));
    }
  });

  test('keeps server Chinese and English-locale descriptions', () {
    expect(
      localizedSkillDescription(
        LocaleStrings.of(1),
        name: 'custom',
        description: '服务端中文说明',
      ),
      '服务端中文说明',
    );
    expect(
      localizedSkillDescription(
        LocaleStrings.of(2),
        name: 'office',
        description: 'English server description',
      ),
      'English server description',
    );
  });

  test('unknown Skills receive a Chinese fallback', () {
    expect(
      localizedSkillDescription(
        LocaleStrings.of(1),
        name: 'future-skill',
        description: 'Unknown future description',
      ),
      contains('future-skill'),
    );
  });
}
