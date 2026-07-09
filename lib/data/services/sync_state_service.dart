import 'package:hive_flutter/hive_flutter.dart';

class SyncStateService {
  static const String _boxName = 'sync_state';
  static const String _cursorKey = 'server_cursor';
  static const String _lastSyncAtKey = 'last_sync_at';

  Box<dynamic>? _box;

  Future<Box<dynamic>> _openBox() async {
    try {
      await Hive.initFlutter();
    } catch (_) {
      // Hive may already be initialized.
    }
    return _box ??= await Hive.openBox<dynamic>(_boxName);
  }

  Future<int> cursor() async {
    final box = await _openBox();
    return (box.get(_cursorKey, defaultValue: 0) as num).toInt();
  }

  Future<void> setCursor(int cursor) async {
    final box = await _openBox();
    await box.put(_cursorKey, cursor);
    await box.put(_lastSyncAtKey, DateTime.now().toUtc().toIso8601String());
  }

  Future<String?> lastSyncAt() async {
    final box = await _openBox();
    return box.get(_lastSyncAtKey) as String?;
  }
}
