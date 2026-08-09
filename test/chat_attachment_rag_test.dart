import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/ai_image_input.dart';
import 'package:memora/data/services/prompt_service.dart';
import 'package:memora/data/services/rag_conversation_service.dart';
import 'package:memora/data/services/retrieval_service.dart';

void main() {
  test('attachments are valid evidence in knowledge-only mode', () async {
    List<AiImageInput>? receivedImages;
    String? receivedUserMessage;
    final service = RagConversationService(
      retrieve: (_, _) async => const RetrievalResult(
        articles: [],
        method: RetrievalMethod.none,
        duration: Duration.zero,
      ),
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async => fail('text completion should not be used'),
      multimodalCompleteStream:
          ({
            required String systemPrompt,
            required String userMessage,
            required List<AiImageInput> images,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async* {
            receivedImages = images;
            receivedUserMessage = userMessage;
            yield 'The chart increased.';
          },
      saveLog: (_) async {},
      promptService: _AttachmentPromptService(),
    );
    final image = AiImageInput(
      id: 'image-1',
      fileName: 'chart.png',
      mimeType: 'image/png',
      bytes: Uint8List.fromList([1, 2, 3]),
    );

    final result = await service.ask(
      RagConversationRequest(
        question: 'What changed?',
        articles: const [],
        knowledgeOnly: true,
        detailedAnswer: false,
        languageHint: '',
        attachmentContext: '### Images\n- chart.png',
        imageInputs: [image],
      ),
    );

    expect(result.outcome, RagConversationOutcome.answer);
    expect(result.answer, 'The chart increased.');
    expect(result.method, 'attachment');
    expect(receivedImages, [image]);
    expect(receivedUserMessage, contains('chart.png'));
  });
}

class _AttachmentPromptService extends PromptService {
  @override
  Future<String> load(String path, [Map<String, String>? vars]) async {
    return switch (path) {
      'chat/system.txt' => 'Answer the user.',
      'chat/user.txt' =>
        'Context: ${vars?['context'] ?? ''}\nQuestion: ${vars?['question'] ?? ''}',
      'chat/attachments.txt' => 'Attachments:\n${vars?['attachments'] ?? ''}',
      _ => path,
    };
  }
}
