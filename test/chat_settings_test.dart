import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive/hive.dart';

import 'package:memora/data/models/settings.dart';
import 'package:memora/shared/providers/passage_providers.dart';
import 'package:memora/shared/providers/settings_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('memora-chat-settings-');
    Hive.init(tempDir.path);
    if (!Hive.isAdapterRegistered(AppSettings.typeId)) {
      Hive.registerAdapter(AppSettingsAdapter());
    }
  });

  tearDown(() async {
    await Hive.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test('chat preferences persist as one settings snapshot', () async {
    final container = ProviderContainer(
      overrides: [
        hiveInitProvider.overrideWith((ref) async {}),
      ],
    );
    addTearDown(container.dispose);

    for (var i = 0;
        i < 20 && !container.read(settingsProvider).hasValue;
        i++) {
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }

    await container.read(settingsProvider.notifier).setChatPreferences(
          answerLength: 1,
          knowledgeSource: 1,
        );

    final state = container.read(settingsProvider).value!;
    expect(state.chatAnswerLengthIndex, 1);
    expect(state.chatKnowledgeSourceIndex, 1);

    final box = await Hive.openBox<AppSettings>('app_settings');
    final persisted = box.get('settings')!;
    expect(persisted.chatAnswerLengthIndex, 1);
    expect(persisted.chatKnowledgeSourceIndex, 1);
  });
}
