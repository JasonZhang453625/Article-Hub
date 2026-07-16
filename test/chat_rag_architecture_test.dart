import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ChatScreen delegates RAG orchestration and renders validated citations',
      () {
    final source = File('lib/features/chat/chat_screen.dart').readAsStringSync();

    expect(source, contains('ragConversationServiceProvider'));
    expect(source, contains('articleIds: result.citedIds'));
    expect(source, isNot(contains('maxContextPerArticle')));
    expect(source, isNot(contains('extractValidCitations')));
    expect(source, isNot(contains('displayIds')));
  });
}
