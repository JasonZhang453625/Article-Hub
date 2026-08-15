import 'package:hive_flutter/hive_flutter.dart';

import 'sync_payload_policy.dart';

/// The last server-authoritative snapshot that this device has observed for
/// one sync entity. It is the base of the client's three-way merge.
class SyncShadow {
  final String accountId;
  final String collection;
  final String itemId;
  final int entityRevision;
  final int serverSeq;
  final Map<String, dynamic>? payload;
  final bool deleted;
  final String? deviceId;

  const SyncShadow({
    required this.accountId,
    required this.collection,
    required this.itemId,
    required this.entityRevision,
    required this.serverSeq,
    required this.payload,
    required this.deleted,
    this.deviceId,
  });

  factory SyncShadow.fromJson(Map<String, dynamic> json) {
    final collection = json['collection'] as String;
    final payload = json['payload'];
    return SyncShadow(
      accountId: json['accountId'] as String,
      collection: collection,
      itemId: json['itemId'] as String,
      entityRevision: _intValue(json['entityRevision']),
      serverSeq: _intValue(json['serverSeq']),
      payload: SyncPayloadPolicy.sanitize(
        collection,
        payload is Map ? Map<String, dynamic>.from(payload) : null,
      ),
      deleted: json['deleted'] == true,
      deviceId: json['deviceId'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'accountId': accountId,
      'collection': collection,
      'itemId': itemId,
      'entityRevision': entityRevision,
      'serverSeq': serverSeq,
      'payload': SyncPayloadPolicy.sanitize(collection, payload),
      'deleted': deleted,
      'deviceId': deviceId,
    };
  }

  SyncShadow copyWith({
    int? entityRevision,
    int? serverSeq,
    Map<String, dynamic>? payload,
    bool? deleted,
    String? deviceId,
  }) {
    return SyncShadow(
      accountId: accountId,
      collection: collection,
      itemId: itemId,
      entityRevision: entityRevision ?? this.entityRevision,
      serverSeq: serverSeq ?? this.serverSeq,
      payload: payload ?? this.payload,
      deleted: deleted ?? this.deleted,
      deviceId: deviceId ?? this.deviceId,
    );
  }
}

class SyncShadowService {
  static const String _boxName = 'sync_shadow';

  Box<dynamic>? _box;

  Future<Box<dynamic>> _openBox() async {
    try {
      await Hive.initFlutter();
    } catch (_) {
      // Hive may already be initialized by the app or a test harness.
    }
    return _box ??= await Hive.openBox<dynamic>(_boxName);
  }

  Future<SyncShadow?> get({
    required String accountId,
    required String collection,
    required String itemId,
  }) async {
    final box = await _openBox();
    final raw = box.get(_key(accountId, collection, itemId));
    if (raw is! Map) return null;
    try {
      final json = Map<String, dynamic>.from(raw);
      final shadow = SyncShadow.fromJson(json);
      final rawPayload = json['payload'];
      if (SyncPayloadPolicy.containsSecrets(
        shadow.collection,
        rawPayload is Map ? Map<String, dynamic>.from(rawPayload) : null,
      )) {
        await box.put(_key(accountId, collection, itemId), shadow.toJson());
      }
      return shadow;
    } catch (_) {
      await box.delete(_key(accountId, collection, itemId));
      return null;
    }
  }

  Future<void> put(SyncShadow shadow) async {
    final box = await _openBox();
    await box.put(
      _key(shadow.accountId, shadow.collection, shadow.itemId),
      shadow.toJson(),
    );
  }

  Future<void> delete({
    required String accountId,
    required String collection,
    required String itemId,
  }) async {
    final box = await _openBox();
    await box.delete(_key(accountId, collection, itemId));
  }

  String _key(String accountId, String collection, String itemId) {
    return '$accountId::$collection::$itemId';
  }
}

int _intValue(dynamic value) {
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}
