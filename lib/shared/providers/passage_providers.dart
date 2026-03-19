import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../data/models/passage.dart';
import '../../data/repositories/passage_repository.dart';

final hiveInitProvider = FutureProvider<void>((ref) async {
  await Hive.initFlutter();
  if (!Hive.isAdapterRegistered(Passage.typeId)) {
    Hive.registerAdapter(PassageAdapter());
  }
  if (!Hive.isAdapterRegistered(1)) {
    Hive.registerAdapter(SourcePlatformAdapter());
  }
});

final passageRepositoryProvider =
    FutureProvider<PassageRepository>((ref) async {
  await ref.watch(hiveInitProvider.future);
  final repo = PassageRepository();
  await repo.init();
  return repo;
});

final passagesProvider =
    StateNotifierProvider<PassagesNotifier, AsyncValue<List<Passage>>>((ref) {
  return PassagesNotifier(ref);
});

class PassagesNotifier
    extends StateNotifier<AsyncValue<List<Passage>>> {
  final Ref _ref;

  PassagesNotifier(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    final repo = await _ref.read(passageRepositoryProvider.future);
    state = AsyncValue.data(repo.getAll());
  }

  Future<void> add(Passage passage) async {
    final repo = await _ref.read(passageRepositoryProvider.future);
    await repo.add(passage);
    state = AsyncValue.data(repo.getAll());
  }

  Future<void> update(Passage passage) async {
    final repo = await _ref.read(passageRepositoryProvider.future);
    await repo.update(passage);
    state = AsyncValue.data(repo.getAll());
  }

  Future<void> delete(String id) async {
    final repo = await _ref.read(passageRepositoryProvider.future);
    await repo.delete(id);
    state = AsyncValue.data(repo.getAll());
  }

  void refresh() {
    _load();
  }
}

final searchQueryProvider = StateProvider<String>((ref) => '');

final selectedPlatformProvider = StateProvider<String>((ref) => '');

final filteredPassagesProvider =
    Provider<AsyncValue<List<Passage>>>((ref) {
  final passagesAsync = ref.watch(passagesProvider);
  final query = ref.watch(searchQueryProvider);
  final platform = ref.watch(selectedPlatformProvider);

  return passagesAsync.whenData((passages) {
    var filtered = passages;

    if (query.isNotEmpty) {
      final lower = query.toLowerCase();
      filtered = filtered.where((p) {
        return p.title.toLowerCase().contains(lower) ||
            p.url.toLowerCase().contains(lower) ||
            p.tags.any((t) => t.toLowerCase().contains(lower));
      }).toList();
    }

    if (platform.isNotEmpty) {
      filtered =
          filtered.where((p) => p.source.name == platform).toList();
    }

    return filtered;
  });
});
