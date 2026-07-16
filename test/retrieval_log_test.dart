import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/services/retrieval_log_service.dart';

void main() {
  group('RetrievalLog model', () {
    test('toMap/fromMap round-trip preserves all fields', () {
      final log = RetrievalLog(
        id: 'log-1',
        query: 'flutter state management',
        rewrittenQuery: 'Flutter state management approaches',
        method: 'vector',
        candidateIds: ['a1', 'a2', 'a3'],
        citedIds: ['a1', 'a3'],
        durationMs: 245,
        timestamp: DateTime(2026, 6, 16, 10, 30),
        feedback: 1,
        clickedCitationIds: ['a1'],
      );

      final map = log.toMap();
      final restored = RetrievalLog.fromMap(map);

      expect(restored.id, 'log-1');
      expect(restored.query, 'flutter state management');
      expect(restored.rewrittenQuery, 'Flutter state management approaches');
      expect(restored.method, 'vector');
      expect(restored.candidateIds, ['a1', 'a2', 'a3']);
      expect(restored.citedIds, ['a1', 'a3']);
      expect(restored.durationMs, 245);
      expect(restored.timestamp, DateTime(2026, 6, 16, 10, 30));
      expect(restored.feedback, 1);
      expect(restored.clickedCitationIds, ['a1']);
    });

    test('fromMap handles missing optional fields', () {
      final map = {
        'id': 'log-2',
        'query': 'test',
        'method': 'keyword',
        'candidateIds': <String>['x1'],
        'durationMs': 100,
        'timestamp': '2026-06-16T12:00:00.000',
      };

      final log = RetrievalLog.fromMap(map);
      expect(log.feedback, isNull);
      expect(log.rewrittenQuery, isNull);
      expect(log.clickedCitationIds, isEmpty);
      expect(log.citedIds, isEmpty);
    });

    test('copyWith updates feedback without changing other fields', () {
      final log = RetrievalLog(
        id: 'log-3',
        query: 'ai trends',
        method: 'vector',
        candidateIds: ['b1', 'b2'],
        citedIds: ['b1'],
        durationMs: 300,
      );

      final updated = log.copyWith(feedback: -1);
      expect(updated.feedback, -1);
      expect(updated.query, 'ai trends');
      expect(updated.candidateIds, ['b1', 'b2']);
      expect(updated.citedIds, ['b1']);
    });

    test('copyWith appends clicked citation IDs', () {
      final log = RetrievalLog(
        id: 'log-4',
        query: 'test',
        method: 'keyword',
        candidateIds: ['c1'],
        durationMs: 50,
        clickedCitationIds: ['c1'],
      );

      final updated = log.copyWith(
        clickedCitationIds: [...log.clickedCitationIds, 'c2'],
      );
      expect(updated.clickedCitationIds, ['c1', 'c2']);
    });

    test('no-result log has method "none" and empty candidates', () {
      final log = RetrievalLog(
        id: 'log-5',
        query: 'quantum computing',
        method: 'none',
        candidateIds: [],
        durationMs: 120,
      );
      expect(log.method, 'none');
      expect(log.candidateIds, isEmpty);
    });
  });

  group('RetrievalLog citation tracking', () {
    test('cited IDs are subset of candidate IDs in valid usage', () {
      final log = RetrievalLog(
        id: 'log-6',
        query: 'electric cars',
        method: 'vector',
        candidateIds: ['x1', 'x2', 'x3'],
        citedIds: ['x1', 'x3'],
        durationMs: 200,
      );
      expect(
        log.citedIds.every((id) => log.candidateIds.contains(id)),
        isTrue,
        reason:
            'All cited IDs should come from candidates (anti-hallucination)',
      );
    });

    test('invalid cited IDs can be detected', () {
      // This simulates what would happen if the model hallucinated an articleId
      final log = RetrievalLog(
        id: 'log-7',
        query: 'test',
        method: 'vector',
        candidateIds: ['real-1', 'real-2'],
        citedIds: ['real-1', 'fake-id'],
        durationMs: 150,
      );
      final invalidCitations = log.citedIds.where(
        (id) => !log.candidateIds.contains(id),
      );
      expect(invalidCitations, isNotEmpty);
      expect(invalidCitations.first, 'fake-id');
    });
  });
}
