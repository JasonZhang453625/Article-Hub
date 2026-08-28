import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/settings.dart';

void main() {
  test(
    'account sync excludes provider keys while local backup includes them',
    () {
      final settings = AppSettings(
        aiBaseUrl: 'https://ai.example/v1',
        aiApiKey: 'sk-ai-secret',
        aiModel: 'model-a',
        chatAiBaseUrl: 'https://chat.example/v1',
        chatAiApiKey: 'sk-chat-secret',
        chatAiModel: 'model-chat',
        imageAiBaseUrl: 'https://vision.example/v1',
        imageAiApiKey: 'sk-image-secret',
        imageAiModel: 'model-vision',
        aiProviderMode: 1,
        hostedAiModel: 'deepseek-v4-flash',
        hostedChatModel: 'deepseek-v4-pro',
        hostedVisionModel: 'sensenova-6.8-flash-lite',
        embeddingBaseUrl: 'https://embedding.example/v1',
        embeddingApiKey: 'sk-embedding-secret',
        embeddingModel: 'model-b',
        tavilyApiKey: 'tvly-secret',
      );

      expect(settings.toJson().containsKey('aiApiKey'), isFalse);
      expect(settings.toJson().containsKey('chatAiApiKey'), isFalse);
      expect(settings.toJson().containsKey('imageAiApiKey'), isFalse);
      expect(settings.toJson().containsKey('embeddingApiKey'), isFalse);
      expect(settings.toJson().containsKey('tavilyApiKey'), isFalse);
      expect(settings.toSyncJson()['schemaVersion'], 2);
      for (final key in const [
        'aiApiKey',
        'chatAiApiKey',
        'imageAiApiKey',
        'embeddingApiKey',
        'tavilyApiKey',
      ]) {
        expect(settings.toSyncJson().containsKey(key), isFalse);
        expect(settings.toBackupJson().containsKey(key), isTrue);
      }
      expect(settings.toSyncJson()['hostedAiModel'], 'deepseek-v4-flash');
      expect(settings.toSyncJson()['hostedChatModel'], 'deepseek-v4-pro');
      expect(
        settings.toSyncJson()['hostedVisionModel'],
        'sensenova-6.8-flash-lite',
      );
    },
  );

  test('legacy shared AI config migrates to chat without enabling vision', () {
    final settings = AppSettings.fromJson({
      'aiBaseUrl': 'https://legacy.example/v1',
      'aiApiKey': 'legacy-secret',
      'aiModel': 'legacy-model',
      'aiProviderMode': 7,
      'hostedAiModel': 'mimo-v2.5-pro',
    });

    expect(settings.chatAiBaseUrl, 'https://legacy.example/v1');
    expect(settings.chatAiApiKey, 'legacy-secret');
    expect(settings.chatAiModel, 'legacy-model');
    expect(settings.imageAiBaseUrl, isEmpty);
    expect(settings.imageAiApiKey, isEmpty);
    expect(settings.aiProviderMode, 0);
    expect(settings.hostedAiModel, AppSettings.defaultHostedTextModel);
    expect(settings.hostedChatModel, AppSettings.defaultHostedTextModel);
    expect(settings.hostedVisionModel, AppSettings.defaultHostedVisionModel);
  });
}
