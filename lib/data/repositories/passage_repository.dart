import 'package:hive/hive.dart';
import '../models/passage.dart';

class PassageRepository {
  static const String _boxName = 'passages';
  late Box<Passage> _box;

  Future<void> init() async {
    _box = await Hive.openBox<Passage>(_boxName);
  }

  List<Passage> getAll() {
    return _box.values.toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
  }

  Passage? getById(String id) {
    return _box.values.firstWhere(
      (p) => p.id == id,
      orElse: () => throw StateError('Passage not found'),
    );
  }

  Future<void> add(Passage passage) async {
    await _box.put(passage.id, passage);
  }

  Future<void> update(Passage passage) async {
    passage.updatedAt = DateTime.now();
    await passage.save();
  }

  Future<void> delete(String id) async {
    await _box.delete(id);
  }

  List<Passage> search(String query) {
    if (query.isEmpty) return getAll();
    final lower = query.toLowerCase();
    return getAll().where((p) {
      return p.title.toLowerCase().contains(lower) ||
          p.url.toLowerCase().contains(lower) ||
          p.tags.any((t) => t.toLowerCase().contains(lower)) ||
          p.notes.toLowerCase().contains(lower);
    }).toList();
  }

  List<Passage> filterByPlatform(String platform) {
    if (platform.isEmpty) return getAll();
    return getAll().where((p) => p.source.name == platform).toList();
  }
}
