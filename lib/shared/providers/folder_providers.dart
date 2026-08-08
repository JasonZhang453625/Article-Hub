import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../data/models/folder.dart';
import '../../data/services/sync_outbox_service.dart';
import 'article_providers.dart';
import 'sync_providers.dart';

final foldersProvider =
    StateNotifierProvider<FoldersNotifier, AsyncValue<List<Folder>>>((ref) {
      return FoldersNotifier(ref);
    });

class FoldersNotifier extends StateNotifier<AsyncValue<List<Folder>>> {
  final Ref _ref;
  static const String _boxName = 'folders';

  FoldersNotifier(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<Box<Folder>> _openBox() async {
    await _ref.read(hiveInitProvider.future);
    return Hive.openBox<Folder>(_boxName);
  }

  Future<void> _load() async {
    final box = await _openBox();
    final folders = box.values.toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    state = AsyncValue.data(folders);
  }

  Future<void> add(Folder folder) async {
    final box = await _openBox();
    await box.put(folder.id, folder);
    await _enqueueFolder(folder);
    await _load();
  }

  Future<void> update(Folder folder) async {
    final box = await _openBox();
    await box.put(folder.id, folder);
    await _enqueueFolder(folder);
    await _load();
  }

  Future<void> delete(String id) async {
    final box = await _openBox();
    final deleted = box.get(id);
    final newParentId = deleted?.parentId;
    await box.delete(id);
    await _ref
        .read(syncMutationProvider)
        .delete(
          accountId: readInitializedSyncAccountId(_ref),
          collection: SyncCollections.folders,
          itemId: id,
        );
    for (final folder in box.values.toList()) {
      if (folder.parentId == id) {
        folder.parentId = newParentId;
        await folder.save();
        await _enqueueFolder(folder);
      }
    }
    await _ref.read(articlesProvider.notifier).clearFolder(id);
    await _load();
  }

  void refresh() => _load();

  Future<void> _enqueueFolder(Folder folder) {
    return _ref
        .read(syncMutationProvider)
        .upsert(
          accountId: readInitializedSyncAccountId(_ref),
          collection: SyncCollections.folders,
          itemId: folder.id,
          payload: folder.toJson(),
        );
  }
}
