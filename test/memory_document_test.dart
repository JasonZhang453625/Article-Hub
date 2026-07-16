import 'package:flutter_test/flutter_test.dart';

import 'package:memora/data/models/memory_document.dart';

void main() {
  group('MemoryDocument', () {
    test('round-trips structured AI memory through JSON-compatible maps', () {
      final generatedAt = DateTime.utc(2026, 7, 16, 8, 30);
      final memory = MemoryDocument.ai(
        revision: 2,
        overview: 'Agent SDK provides a unified agent framework.',
        keyPoints: const [
          MemoryKeyPoint(
            id: 'kp-1',
            order: 1,
            topic: 'Handoff',
            content: 'Agents can hand tasks to a better-suited agent.',
            sourceRefs: ['primary'],
          ),
          MemoryKeyPoint(
            id: 'kp-2',
            order: 2,
            topic: 'Tracing',
            content: 'Tracing records model, tool, and handoff activity.',
          ),
        ],
        conclusion: 'The SDK standardizes multi-agent applications.',
        generation: MemoryGeneration(
          method: 'llm',
          provider: 'openai-compatible',
          model: 'gpt-test',
          promptVersion: 'full_summary_v1',
          generatedAt: generatedAt,
        ),
      );

      final restored = MemoryDocument.fromJson(memory.toJson());

      expect(restored.kind, MemoryKind.aiMemory);
      expect(restored.revision, 2);
      expect(restored.overview, memory.overview);
      expect(restored.keyPoints, hasLength(2));
      expect(restored.keyPoints.first.id, 'kp-1');
      expect(restored.keyPoints.first.order, 1);
      expect(restored.keyPoints.first.sourceRefs, ['primary']);
      expect(restored.generation?.model, 'gpt-test');
      expect(restored.generation?.generatedAt, generatedAt);
    });

    test('accepts Hive maps whose keys and nested maps are dynamic', () {
      final restored = MemoryDocument.fromJson(<dynamic, dynamic>{
        'kind': 'ai_memory',
        'revision': 1,
        'overview': 'Overview',
        'keyPoints': <dynamic>[
          <dynamic, dynamic>{
            'id': 'kp-dynamic',
            'order': 1,
            'topic': 'Topic',
            'content': 'Content',
            'sourceRefs': <dynamic>[],
          },
        ],
        'conclusion': 'Conclusion',
      });

      expect(restored.keyPoints.single.id, 'kp-dynamic');
    });

    test('renders Markdown only at the display boundary', () {
      final memory = MemoryDocument.ai(
        overview: 'Overview text.',
        keyPoints: const [
          MemoryKeyPoint(
            id: 'kp-1',
            order: 1,
            topic: 'First topic',
            content: 'First fact.',
          ),
        ],
        conclusion: 'Conclusion text.',
      );

      expect(
        memory.toMarkdown(),
        '**摘要**\n\nOverview text.\n\n'
        '**要点**\n\n1. **First topic**：First fact.\n\n'
        '**总结**\n\nConclusion text.',
      );
    });

    test('builds marker-free retrieval text from every semantic field', () {
      final memory = MemoryDocument.ai(
        overview: 'Overview text.',
        keyPoints: const [
          MemoryKeyPoint(
            id: 'kp-1',
            order: 1,
            topic: 'Handoff',
            content: 'Delegates work.',
          ),
        ],
        conclusion: 'Conclusion text.',
      );

      expect(
        memory.toRetrievalText(),
        'Overview text.\nHandoff\nDelegates work.\nConclusion text.',
      );
      expect(memory.toRetrievalText(), isNot(contains('**')));
    });

    test('full-text memory preserves the original body and format', () {
      final memory = MemoryDocument.fullText(
        body: '# Imported title\n\nOriginal body.',
        format: 'markdown',
      );

      expect(memory.kind, MemoryKind.fullText);
      expect(memory.toMarkdown(), '# Imported title\n\nOriginal body.');
      expect(memory.toRetrievalText(), '# Imported title\n\nOriginal body.');
      expect(memory.toJson()['format'], 'markdown');
    });
  });
}
