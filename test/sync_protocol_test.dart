import 'package:flutter_test/flutter_test.dart';
import 'package:memora/data/services/sync_protocol.dart';

void main() {
  test('wraps and validates a versioned account-bound entity payload', () {
    final wrapped = SyncProtocol.wrapPayload(
      accountId: 'user-1',
      collection: 'articles',
      itemId: 'article-1',
      data: {'schemaVersion': 2, 'id': 'article-1'},
    );

    expect(wrapped['format'], SyncProtocol.envelopeFormat);
    expect(
      SyncProtocol.unwrapPayload(
        wrapped,
        accountId: 'user-1',
        collection: 'articles',
        itemId: 'article-1',
      )['id'],
      'article-1',
    );
  });

  test('rejects replaying an envelope into another account', () {
    final wrapped = SyncProtocol.wrapPayload(
      accountId: 'user-1',
      collection: 'articles',
      itemId: 'article-1',
      data: {'id': 'article-1'},
    );

    expect(
      () => SyncProtocol.unwrapPayload(
        wrapped,
        accountId: 'user-2',
        collection: 'articles',
        itemId: 'article-1',
      ),
      throwsA(isA<SyncProtocolException>()),
    );
  });

  test('keeps legacy unwrapped payloads readable', () {
    final legacy = {'id': 'article-legacy', 'title': 'Legacy'};
    expect(
      SyncProtocol.unwrapPayload(
        legacy,
        accountId: 'user-1',
        collection: 'articles',
        itemId: 'article-legacy',
      ),
      legacy,
    );
  });
}
