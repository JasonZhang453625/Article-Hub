class SyncProtocol {
  static const int protocolVersion = 3;
  static const int envelopeSchemaVersion = 1;
  static const String envelopeFormat = 'memora.sync.entity';
  static const String payloadFormat = 'memora.sync.json';

  const SyncProtocol._();

  static Map<String, dynamic> wrapPayload({
    required String accountId,
    required String collection,
    required String itemId,
    required Map<String, dynamic> data,
  }) {
    _requireNonEmpty(accountId, 'accountId');
    _requireNonEmpty(collection, 'collection');
    _requireNonEmpty(itemId, 'itemId');
    return {
      'format': envelopeFormat,
      'schemaVersion': envelopeSchemaVersion,
      'accountId': accountId,
      'collection': collection,
      'itemId': itemId,
      'data': data,
    };
  }

  /// Returns legacy unwrapped payloads unchanged so data uploaded by older
  /// clients remains readable after the protocol upgrade.
  static Map<String, dynamic> unwrapPayload(
    Map<String, dynamic> payload, {
    required String accountId,
    required String collection,
    required String itemId,
  }) {
    if (payload['format'] != envelopeFormat) return payload;

    if (payload['schemaVersion'] != envelopeSchemaVersion) {
      throw const SyncProtocolException('Unsupported sync envelope schema.');
    }
    if (payload['accountId'] != accountId ||
        payload['collection'] != collection ||
        payload['itemId'] != itemId) {
      throw const SyncProtocolException('Sync envelope identity mismatch.');
    }
    final data = payload['data'];
    if (data is! Map) {
      throw const SyncProtocolException(
        'Sync envelope is missing entity data.',
      );
    }
    return Map<String, dynamic>.from(data);
  }

  static int entitySchemaVersion(Map<String, dynamic>? payload) {
    final value = payload?['schemaVersion'];
    return value is num ? value.toInt() : 1;
  }

  static void _requireNonEmpty(String value, String name) {
    if (value.trim().isEmpty) {
      throw SyncProtocolException('$name must not be empty.');
    }
  }
}

class SyncProtocolException implements Exception {
  final String message;

  const SyncProtocolException(this.message);

  @override
  String toString() => message;
}
