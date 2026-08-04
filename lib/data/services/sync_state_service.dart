import 'package:hive_flutter/hive_flutter.dart';

class SyncStateService {
  static const String _boxName = 'sync_state';
  static const String _cursorKey = 'server_cursor';
  static const String _lastSyncAtKey = 'last_sync_at';
  static const String _initializedKey = 'initialized';
  static const String _initializedProtocolKey = 'initialized_protocol';
  static const String _legacyOwnerKey = 'legacy_state_owner';
  static const String _vaultOwnerKey = 'local_vault_owner';

  Box<dynamic>? _box;

  Future<Box<dynamic>> _openBox() async {
    try {
      await Hive.initFlutter();
    } catch (_) {
      // Hive may already be initialized.
    }
    return _box ??= await Hive.openBox<dynamic>(_boxName);
  }

  Future<int> cursor(String accountId) async {
    final box = await _openBox();
    await _migrateLegacyState(box, accountId);
    return (box.get(_scoped(_cursorKey, accountId), defaultValue: 0) as num)
        .toInt();
  }

  Future<void> setCursor(String accountId, int cursor) async {
    final box = await _openBox();
    await box.put(_scoped(_cursorKey, accountId), cursor);
    await box.put(
      _scoped(_lastSyncAtKey, accountId),
      DateTime.now().toUtc().toIso8601String(),
    );
  }

  Future<String?> lastSyncAt(String accountId) async {
    final box = await _openBox();
    await _migrateLegacyState(box, accountId);
    return box.get(_scoped(_lastSyncAtKey, accountId)) as String?;
  }

  Future<bool> isInitialized(
    String accountId, {
    required int protocolVersion,
  }) async {
    final box = await _openBox();
    final initialized = box.get(_scoped(_initializedKey, accountId)) == true;
    final storedProtocol =
        (box.get(_scoped(_initializedProtocolKey, accountId), defaultValue: 0)
                as num)
            .toInt();
    return initialized && storedProtocol >= protocolVersion;
  }

  Future<void> ensureVaultOwner(String accountId) async {
    final box = await _openBox();
    final owner = box.get(_vaultOwnerKey);
    if (owner == null) {
      await box.put(_vaultOwnerKey, accountId);
      return;
    }
    if (owner != accountId) {
      throw const SyncAccountMismatchException();
    }
  }

  Future<String?> vaultOwner() async {
    final box = await _openBox();
    return box.get(_vaultOwnerKey) as String?;
  }

  Future<void> setInitialized(
    String accountId,
    bool value, {
    required int protocolVersion,
  }) async {
    final box = await _openBox();
    await box.put(_scoped(_initializedKey, accountId), value);
    await box.put(
      _scoped(_initializedProtocolKey, accountId),
      value ? protocolVersion : 0,
    );
  }

  Future<void> resetAccount(String accountId) async {
    final box = await _openBox();
    await box.put(_scoped(_cursorKey, accountId), 0);
    await box.delete(_scoped(_lastSyncAtKey, accountId));
    await box.put(_scoped(_initializedKey, accountId), false);
    await box.put(_scoped(_initializedProtocolKey, accountId), 0);
  }

  String _scoped(String key, String accountId) => '$key:$accountId';

  Future<void> _migrateLegacyState(Box<dynamic> box, String accountId) async {
    final scopedCursor = _scoped(_cursorKey, accountId);
    if (box.containsKey(scopedCursor)) return;

    final owner = box.get(_legacyOwnerKey);
    if (owner != null && owner != accountId) return;
    final legacyCursor = box.get(_cursorKey);
    if (legacyCursor is! num) return;

    await box.put(_legacyOwnerKey, accountId);
    await box.put(scopedCursor, legacyCursor.toInt());
    final legacyLastSyncAt = box.get(_lastSyncAtKey);
    if (legacyLastSyncAt is String) {
      await box.put(_scoped(_lastSyncAtKey, accountId), legacyLastSyncAt);
    }
  }
}

class SyncAccountMismatchException implements Exception {
  final String message;

  const SyncAccountMismatchException()
    : message = '本地资料库已绑定到另一个账号。为防止记忆串号，当前账号不会同步；请切回原账号，或使用明确的数据迁移流程。';

  @override
  String toString() => message;
}
