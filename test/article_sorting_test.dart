import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/models/passage.dart';
import 'package:memora/data/models/source_platform.dart';
import 'package:memora/shared/providers/display_providers.dart';

void main() {
  group('sortArticlesByCreatedAt', () {
    final oldest = _article(
      id: 'oldest',
      createdAt: DateTime(2025, 1, 1),
      updatedAt: DateTime(2025, 3, 1),
    );
    final middle = _article(
      id: 'middle',
      createdAt: DateTime(2025, 2, 1),
      updatedAt: DateTime(2025, 2, 1),
    );
    final newest = _article(
      id: 'newest',
      createdAt: DateTime(2025, 3, 1),
      updatedAt: DateTime(2025, 1, 1),
    );

    test('puts newest created memory first by default direction', () {
      final sorted = sortArticlesByCreatedAt([
        middle,
        oldest,
        newest,
      ], newestFirst: true);

      expect(sorted.map((article) => article.id), [
        'newest',
        'middle',
        'oldest',
      ]);
    });

    test('puts oldest created memory first when ascending is selected', () {
      final sorted = sortArticlesByCreatedAt([
        middle,
        newest,
        oldest,
      ], newestFirst: false);

      expect(sorted.map((article) => article.id), [
        'oldest',
        'middle',
        'newest',
      ]);
    });
  });
}

Article _article({
  required String id,
  required DateTime createdAt,
  required DateTime updatedAt,
}) {
  return Article(
    id: id,
    url: 'https://example.com/$id',
    title: id,
    source: SourcePlatform.web,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );
}
