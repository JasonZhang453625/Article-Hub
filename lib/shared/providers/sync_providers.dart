import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/sync_apply_service.dart';
import '../../data/services/sync_crypto_service.dart';
import '../../data/services/sync_outbox_service.dart';
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

final syncCryptoProvider = Provider<SyncCryptoService>((ref) {
  return SyncCryptoService();
});

final syncApplyProvider = Provider<SyncApplyService>((ref) {
  return SyncApplyService(
    crypto: ref.watch(syncCryptoProvider),
    outbox: ref.watch(syncOutboxProvider),
  );
});

final syncServiceProvider = Provider<SyncService>((ref) {
  return SyncService(
    outbox: ref.watch(syncOutboxProvider),
    state: ref.watch(syncStateProvider),
    crypto: ref.watch(syncCryptoProvider),
    applier: ref.watch(syncApplyProvider),
  );
});

final syncNowProvider = FutureProvider.autoDispose<SyncResult?>((ref) async {
  final session = ref.watch(currentSessionProvider);
  if (session == null) return null;
  final service = ref.watch(syncServiceProvider);
  SyncResult result;
  try {
    result = await service.sync(session);
  } on SyncApiException catch (error) {
    if (error.statusCode != 401) rethrow;
    final refreshed = await ref.read(authControllerProvider.notifier).refresh();
    if (refreshed == null) rethrow;
    result = await service.sync(refreshed);
  }
  if (result.applied > 0) {
    ref.invalidate(articleRepositoryProvider);
    ref.invalidate(articlesProvider);
    ref.invalidate(foldersProvider);
    ref.invalidate(filterGroupsProvider);
    ref.invalidate(settingsProvider);
  }
  ref.invalidate(syncOutboxCountProvider);
  return result;
});

final syncOutboxCountProvider = FutureProvider<int>((ref) async {
  return ref.watch(syncOutboxProvider).count();
});

final syncLastSyncAtProvider = FutureProvider<String?>((ref) async {
  return ref.watch(syncStateProvider).lastSyncAt();
});
