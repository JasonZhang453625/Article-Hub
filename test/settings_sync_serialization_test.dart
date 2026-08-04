import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/settings.dart';

void main() {
  test('generic JSON excludes keys while account sync includes them', () {
    final settings = AppSettings(
      aiBaseUrl: 'https://ai.example/v1',
      aiApiKey: 'sk-ai-secret',
      aiModel: 'model-a',
      embeddingBaseUrl: 'https://embedding.example/v1',
      embeddingApiKey: 'sk-embedding-secret',
      embeddingModel: 'model-b',
    );

    expect(settings.toJson().containsKey('aiApiKey'), isFalse);
    expect(settings.toJson().containsKey('embeddingApiKey'), isFalse);
    expect(settings.toSyncJson()['aiApiKey'], 'sk-ai-secret');
    expect(settings.toSyncJson()['embeddingApiKey'], 'sk-embedding-secret');
  });
}
