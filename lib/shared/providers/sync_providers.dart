import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../data/models/filter_group.dart';
import '../../data/models/folder.dart';
import '../../data/models/settings.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/sync_apply_service.dart';
import '../../data/services/sync_outbox_service.dart';
import '../../data/services/sync_protocol.dart';
import '../../data/services/sync_service.dart';
import '../../data/services/sync_state_service.dart';
import 'article_providers.dart';
import 'auth_provider.dart';
import 'filter_providers.dart';
import 'folder_providers.dart';
import 'settings_providers.dart';

final syncOutboxProvider = Provider<SyncOutboxService>((ref) {
  return SyncOutboxService();
});

final syncStateProvider = Provider<SyncStateService>((ref) {
  return SyncStateService();
});

final syncApplyProvider = Provider<SyncApplyService>((ref) {
  return SyncApplyService(outbox: ref.watch(syncOutboxProvider));
});

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(
    outbox: ref.watch(syncOutboxProvider),
    state: ref.watch(syncStateProvider),
    applier: ref.watch(syncApplyProvider),
  );
});

final _syncCoordinatorProvider = Provider<_SyncCoordinator>((ref) {
  return _SyncCoordinator();
});

final syncNowProvider = FutureProvider.autoDispose<SyncResult?>((ref) async {
  final session = ref.watch(currentSessionProvider);
  if (session == null) return null;
  final coordinator = ref.watch(_syncCoordinatorProvider);

  Future<SyncResult> run(AuthSession current) {
    return coordinator.run(() => _runAccountSync(ref, current));
  }

  SyncResult result;
  try {
    result = await run(session);
  } on SyncApiException catch (error) {
    if (error.statusCode != 401) rethrow;
    final refreshed = await ref.read(authControllerProvider.notifier).refresh();
    if (refreshed == null) rethrow;
    result = await run(refreshed);
  }
  if (result.applied > 0) {
    ref.invalidate(articleRepositoryProvider);
    ref.invalidate(articlesProvider);
    ref.invalidate(foldersProvider);
    ref.invalidate(filterGroupsProvider);
    ref.invalidate(settingsProvider);
  }
  return result;
});

final syncOutboxCountProvider = StreamProvider<int>((ref) async* {
  final accountId = ref.watch(currentSessionProvider)?.user.id;
  if (accountId == null) {
    yield 0;
    return;
  }
  yield* ref.watch(syncOutboxProvider).watchCount(accountId: accountId);
});

final syncLastSyncAtProvider = FutureProvider<String?>((ref) async {
  final accountId = ref.watch(currentSessionProvider)?.user.id;
  if (accountId == null) return null;
  return ref.watch(syncStateProvider).lastSyncAt(accountId);
});

Future<SyncResult> _runAccountSync(Ref ref, AuthSession session) async {
  final accountId = session.user.id;
  final state = ref.read(syncStateProvider);
  final service = ref.read(syncServiceProvider);
  await state.ensureVaultOwner(accountId);
  if (await state.isInitialized(
    accountId,
    protocolVersion: SyncProtocol.protocolVersion,
  )) {
    return service.sync(session);
  }

  // Protect local-first entities before the first cloud bootstrap. Remote
  // records with different IDs merge in; equal IDs keep the pending local
  // version. Settings are deliberately seeded after bootstrap so a fresh
  // device's defaults never overwrite the account's existing AI config.
  await _enqueueLocalSnapshot(ref, accountId, includeSettings: false);
  final bootstrap = await service.bootstrapAndApply(session);
  await _enqueueLocalSnapshot(ref, accountId, includeSettings: true);
  final incremental = await service.sync(session);
  await state.setInitialized(
    accountId,
    true,
    protocolVersion: SyncProtocol.protocolVersion,
  );
  return bootstrap.combine(incremental);
}

Future<void> _enqueueLocalSnapshot(
  Ref ref,
  String accountId, {
  required bool includeSettings,
}) async {
  await ref.read(hiveInitProvider.future);
  final outbox = ref.read(syncOutboxProvider);
  final repository = await ref.read(articleRepositoryProvider.future);

  for (final article in repository.getAll()) {
    await outbox.enqueue(
      SyncOutboxRecord.create(
        accountId: accountId,
        collection: SyncCollections.articles,
        itemId: article.id,
        operation: SyncOperation.upsert,
        payload: article.toJson(),
      ),
    );
  }

  final folders = await Hive.openBox<Folder>('folders');
  for (final folder in folders.values) {
    await outbox.enqueue(
      SyncOutboxRecord.create(
        accountId: accountId,
        collection: SyncCollections.folders,
        itemId: folder.id,
        operation: SyncOperation.upsert,
        payload: folder.toJson(),
      ),
    );
  }

  final filterGroups = await Hive.openBox<FilterGroup>('filter_groups');
  for (final group in filterGroups.values) {
    await outbox.enqueue(
      SyncOutboxRecord.create(
        accountId: accountId,
        collection: SyncCollections.filterGroups,
        itemId: group.id,
        operation: SyncOperation.upsert,
        payload: group.toJson(),
      ),
    );
  }

  if (!includeSettings) return;
  final settings = await Hive.openBox<AppSettings>('app_settings');
  final current = settings.get('settings');
  if (current == null) return;
  await outbox.enqueue(
    SyncOutboxRecord.create(
      accountId: accountId,
      collection: SyncCollections.appSettings,
      itemId: 'settings',
      operation: SyncOperation.upsert,
      payload: current.toSyncJson(),
    ),
  );
}

class _SyncCoordinator {
  Future<SyncResult>? _active;

  Future<SyncResult> run(Future<SyncResult> Function() operation) async {
    final active = _active;
    if (active != null) return active;
    final next = operation();
    _active = next;
    try {
      return await next;
    } finally {
      if (identical(_active, next)) _active = null;
    }
  }
}
