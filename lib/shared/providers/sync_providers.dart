import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';

import '../../data/models/filter_group.dart';
import '../../data/models/folder.dart';
import '../../data/models/settings.dart';
import '../../data/services/auth_service.dart';
import '../../data/services/sync_apply_service.dart';
import '../../data/services/sync_conflict_service.dart';
import '../../data/services/sync_conflict_resolver.dart';
import '../../data/services/sync_mutation_service.dart';
import '../../data/services/sync_outbox_service.dart';
import '../../data/services/sync_payload_policy.dart';
import '../../data/services/sync_protocol.dart';
import '../../data/services/sync_service.dart';
import '../../data/services/sync_shadow_service.dart';
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

final syncShadowProvider = Provider<SyncShadowService>((ref) {
  return SyncShadowService();
});

final syncConflictProvider = Provider<SyncConflictService>((ref) {
  return SyncConflictService();
});

final syncMutationProvider = Provider<SyncMutationService>((ref) {
  return SyncMutationService(
    outbox: ref.watch(syncOutboxProvider),
    shadow: ref.watch(syncShadowProvider),
  );
});

final syncConflictResolverProvider = Provider<SyncConflictResolver>((ref) {
  return SyncConflictResolver(
    applier: ref.watch(syncApplyProvider),
    conflicts: ref.watch(syncConflictProvider),
    mutations: ref.watch(syncMutationProvider),
    outbox: ref.watch(syncOutboxProvider),
  );
});

final syncApplyProvider = Provider<SyncApplyService>((ref) {
  return SyncApplyService(
    outbox: ref.watch(syncOutboxProvider),
    shadow: ref.watch(syncShadowProvider),
    conflicts: ref.watch(syncConflictProvider),
  );
});

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(
    outbox: ref.watch(syncOutboxProvider),
    state: ref.watch(syncStateProvider),
    applier: ref.watch(syncApplyProvider),
    shadow: ref.watch(syncShadowProvider),
    conflicts: ref.watch(syncConflictProvider),
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

final syncConflictCountProvider = StreamProvider<int>((ref) async* {
  final accountId = ref.watch(currentSessionProvider)?.user.id;
  if (accountId == null) {
    yield 0;
    return;
  }
  yield* ref.watch(syncConflictProvider).watchCount(accountId: accountId);
});

final syncConflictsProvider = FutureProvider<List<SyncConflictRecord>>((ref) {
  final accountId = ref.watch(currentSessionProvider)?.user.id;
  return ref.watch(syncConflictProvider).pending(accountId: accountId);
});

/// Reads the account only when auth has already been initialized. Local-first
/// feature tests and signed-out writes must not force AuthService to open its
/// Hive session box just to enqueue a local mutation.
String? readInitializedSyncAccountId(Ref ref) {
  try {
    if (!ref.exists(currentSessionProvider)) return null;
    return ref.read(currentSessionProvider)?.user.id;
  } catch (_) {
    return null;
  }
}

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

  // Bootstrap first so the server snapshot becomes the three-way merge base.
  // Local records are then enqueued as mutations; equal IDs are either merged
  // safely or surfaced in the conflict inbox instead of being overwritten.
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
  final repository = await ref.read(articleRepositoryProvider.future);

  for (final article in repository.getAll()) {
    await _enqueueSnapshotMutation(
      ref,
      accountId: accountId,
      collection: SyncCollections.articles,
      itemId: article.id,
      payload: article.toJson(),
    );
  }

  final folders = await Hive.openBox<Folder>('folders');
  for (final folder in folders.values) {
    await _enqueueSnapshotMutation(
      ref,
      accountId: accountId,
      collection: SyncCollections.folders,
      itemId: folder.id,
      payload: folder.toJson(),
    );
  }

  final filterGroups = await Hive.openBox<FilterGroup>('filter_groups');
  for (final group in filterGroups.values) {
    await _enqueueSnapshotMutation(
      ref,
      accountId: accountId,
      collection: SyncCollections.filterGroups,
      itemId: group.id,
      payload: group.toJson(),
    );
  }

  if (!includeSettings) return;
  final settings = await Hive.openBox<AppSettings>('app_settings');
  final current = settings.get('settings');
  if (current == null) return;
  await _enqueueSnapshotMutation(
    ref,
    accountId: accountId,
    collection: SyncCollections.appSettings,
    itemId: 'settings',
    payload: current.toSyncJson(),
  );
}

Future<void> _enqueueSnapshotMutation(
  Ref ref, {
  required String accountId,
  required String collection,
  required String itemId,
  required Map<String, dynamic> payload,
}) async {
  final sanitizedPayload = SyncPayloadPolicy.sanitize(collection, payload)!;
  final base = await ref
      .read(syncShadowProvider)
      .get(accountId: accountId, collection: collection, itemId: itemId);
  final sanitizedBasePayload = SyncPayloadPolicy.sanitize(
    collection,
    base?.payload,
  );
  final changedPaths = jsonChangedPaths(sanitizedBasePayload, sanitizedPayload);
  if (base != null && !base.deleted && changedPaths.isEmpty) return;
  await ref
      .read(syncOutboxProvider)
      .enqueue(
        SyncOutboxRecord.create(
          accountId: accountId,
          collection: collection,
          itemId: itemId,
          operation: SyncOperation.upsert,
          payload: sanitizedPayload,
          baseEntityRevision: base?.entityRevision ?? 0,
          basePayload: sanitizedBasePayload,
          changedPaths: changedPaths,
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
