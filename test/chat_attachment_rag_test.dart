import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/ai_image_input.dart';
import 'package:memora/data/models/ai_file_attachment_input.dart';
import 'package:memora/data/models/ai_text_attachment_input.dart';
import 'package:memora/data/services/hosted_agent_service.dart';
import 'package:memora/data/services/prompt_service.dart';
import 'package:memora/data/services/rag_conversation_service.dart';

void main() {
  test(
    'attachments bypass retrieval and go directly to the chat model',
    () async {
      List<AiImageInput>? receivedImages;
      String? receivedUserMessage;
      String? receivedSystemPrompt;
      final service = RagConversationService(
        retrieve: (_, _) async => fail('attachments must not enter retrieval'),
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
              receivedSystemPrompt = systemPrompt;
              yield 'The chart increased.';
            },
        saveLog: (_) async {},
        promptService: _AttachmentPromptService(),
        webSearch: (_, {topK = 5}) async =>
            fail('attachments must not enter web search'),
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
          webSearch: true,
          attachmentContext: '### Images\n- chart.png',
          imageInputs: [image],
        ),
      );

      expect(result.outcome, RagConversationOutcome.answer);
      expect(result.answer, 'The chart increased.');
      expect(result.method, 'attachment');
      expect(receivedImages, [image]);
      expect(receivedUserMessage, contains('chart.png'));
      expect(receivedSystemPrompt, contains('Direct attachment mode'));
      expect(receivedSystemPrompt, contains('不要执行本地知识库检索或联网搜索'));
      expect(receivedUserMessage, isNot(contains('Knowledge context')));
    },
  );

  test('text attachments also bypass retrieval and web search', () async {
    String? receivedUserMessage;
    String? receivedSystemPrompt;
    final service = RagConversationService(
      retrieve: (_, _) async => fail('attachments must not enter retrieval'),
      complete:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async => fail('stream completion should be used'),
      completeStream:
          ({
            required String systemPrompt,
            required String userMessage,
            List<Map<String, String>> history = const [],
            double temperature = 0.3,
            int maxTokens = 800,
          }) async* {
            receivedUserMessage = userMessage;
            receivedSystemPrompt = systemPrompt;
            yield 'The file contains release notes.';
          },
      saveLog: (_) async {},
      promptService: _AttachmentPromptService(),
      webSearch: (_, {topK = 5}) async =>
          fail('attachments must not enter web search'),
    );

    final result = await service.ask(
      const RagConversationRequest(
        question: 'Summarize the file.',
        articles: [],
        knowledgeOnly: false,
        detailedAnswer: false,
        languageHint: '',
        webSearch: true,
        attachmentContext: '### File: notes.md\nRelease 2.1.21 fixes chat.',
      ),
    );

    expect(result.outcome, RagConversationOutcome.answer);
    expect(result.method, 'attachment');
    expect(result.answer, 'The file contains release notes.');
    expect(receivedUserMessage, contains('Release 2.1.21 fixes chat.'));
    expect(receivedSystemPrompt, contains('不要执行本地知识库检索或联网搜索'));
  });

  test(
    'hosted attachments use typed chat@2 input and propagate provenance',
    () async {
      List<Map<String, dynamic>>? receivedHistory;
      List<AiTextAttachmentInput>? receivedAttachments;
      List<String>? receivedSkills;
      bool? receivedWebSearch;
      final service = RagConversationService(
        retrieve: (_, _) async => fail('hosted chat must not enter retrieval'),
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async => fail('hosted chat must not use direct completion'),
        hostedChatRunStream:
            ({
              required String question,
              required List<Map<String, dynamic>> history,
              required HostedChatKnowledgeMode knowledgeMode,
              required HostedChatLength length,
              required HostedChatLanguage language,
              required bool webSearch,
              required bool localKnowledge,
              List<String>? enabledSkills,
              required List<AiTextAttachmentInput> attachments,
              required List<AiFileAttachmentInput> files,
              required List<AiImageInput> images,
              void Function(HostedAgentEvent event)? onEvent,
              FutureOr<void> Function(String runId)? onRunCreated,
              required String idempotencyKey,
            }) async* {
              receivedHistory = history;
              receivedAttachments = attachments;
              receivedSkills = enabledSkills;
              receivedWebSearch = webSearch;
              expect(question, 'Summarize privately.');
              expect(idempotencyKey, 'hosted-private-attempt');
              yield 'Private summary.';
            },
        agentPrivateEvidenceUsed: () => true,
        saveLog: (_) async {},
        promptService: _AttachmentPromptService(),
        webSearch: (_, {topK = 5}) async =>
            fail('private hosted chat must not prefetch Web'),
      );
      const attachment = AiTextAttachmentInput(
        id: 'text-1',
        name: 'private.txt',
        text: 'private current evidence',
      );

      final result = await service.askWithProgress(
        const RagConversationRequest(
          question: 'Summarize privately.',
          history: [
            RagConversationTurn(
              role: 'user',
              content: 'earlier private q',
              privateEvidence: true,
            ),
            RagConversationTurn(
              role: 'assistant',
              content: 'earlier private a',
              privateEvidence: true,
            ),
          ],
          articles: [],
          knowledgeOnly: false,
          detailedAnswer: false,
          languageHint: '',
          webSearch: true,
          enabledSkills: ['summarize'],
          textAttachments: [attachment],
        ),
        idempotencyKey: 'hosted-private-attempt',
      );

      expect(result.outcome, RagConversationOutcome.answer);
      expect(result.answer, 'Private summary.');
      expect(result.privateEvidenceUsed, isTrue);
      expect(receivedWebSearch, isFalse);
      expect(receivedAttachments, [attachment]);
      expect(receivedSkills, ['summarize']);
      expect(receivedHistory, [
        {
          'role': 'user',
          'content': 'earlier private q',
          'private_evidence': true,
        },
        {
          'role': 'assistant',
          'content': 'earlier private a',
          'private_evidence': true,
        },
      ]);
    },
  );

  test(
    'hosted chat keeps Web disabled when sticky private history is trimmed',
    () async {
      final receivedHistories = <List<Map<String, dynamic>>>[];
      final receivedWebSearchValues = <bool>[];
      final service = RagConversationService(
        retrieve: (_, _) async => fail('hosted chat must not enter retrieval'),
        complete:
            ({
              required String systemPrompt,
              required String userMessage,
              List<Map<String, String>> history = const [],
              double temperature = 0.3,
              int maxTokens = 800,
            }) async => fail('hosted chat must not use direct completion'),
        hostedChatRunStream:
            ({
              required String question,
              required List<Map<String, dynamic>> history,
              required HostedChatKnowledgeMode knowledgeMode,
              required HostedChatLength length,
              required HostedChatLanguage language,
              required bool webSearch,
              required bool localKnowledge,
              List<String>? enabledSkills,
              required List<AiTextAttachmentInput> attachments,
              required List<AiFileAttachmentInput> files,
              required List<AiImageInput> images,
              void Function(HostedAgentEvent event)? onEvent,
              FutureOr<void> Function(String runId)? onRunCreated,
              required String idempotencyKey,
            }) async* {
              receivedHistories.add(history);
              receivedWebSearchValues.add(webSearch);
              yield 'Safe answer.';
            },
        agentPrivateEvidenceUsed: () => false,
        saveLog: (_) async {},
        promptService: _AttachmentPromptService(),
        webSearch: (_, {topK = 5}) async =>
            fail('sticky private history must not prefetch Web'),
      );
      final oversizedPrivateTurn = List.filled(4000, 'private').join(' ');

      final result = await service.askWithProgress(
        RagConversationRequest(
          question: 'Can I search now?',
          history: [
            RagConversationTurn(
              role: 'user',
              content: oversizedPrivateTurn,
              privateEvidence: true,
            ),
            const RagConversationTurn(
              role: 'assistant',
              content: 'Earlier private answer.',
              privateEvidence: true,
            ),
          ],
          articles: const [],
          knowledgeOnly: false,
          detailedAnswer: false,
          languageHint: '',
          webSearch: true,
          contextWindowTokens: 2048,
        ),
        idempotencyKey: 'trimmed-private-history',
      );

      expect(result.outcome, RagConversationOutcome.answer);
      expect(receivedHistories.single, isEmpty);
      expect(receivedWebSearchValues.single, isFalse);

      final retryResult = await service.askWithProgress(
        const RagConversationRequest(
          question: 'Retry the private answer.',
          history: [],
          articles: [],
          knowledgeOnly: false,
          detailedAnswer: false,
          languageHint: '',
          webSearch: true,
          privateEvidenceContext: true,
        ),
        idempotencyKey: 'private-retry-context',
      );

      expect(retryResult.outcome, RagConversationOutcome.answer);
      expect(receivedHistories.last, isEmpty);
      expect(receivedWebSearchValues, [false, false]);
    },
  );
}

class _AttachmentPromptService extends PromptService {
  @override
  Future<String> load(String path, [Map<String, String>? vars]) async {
    return switch (path) {
      'chat/attachments_direct_system.txt' =>
        'Direct attachment mode. ${vars?['toolRule'] ?? ''} '
            '${vars?['lengthRule'] ?? ''}',
      'chat/length_concise.txt' => 'Be concise.',
      'chat/attachments.txt' => 'Attachments:\n${vars?['attachments'] ?? ''}',
      _ => path,
    };
  }
}
