import 'sync_conflict_service.dart';
import 'sync_outbox_service.dart';
import 'sync_shadow_service.dart';

/// Records local mutations together with the last server snapshot they were
/// based on. All feature providers use this boundary instead of constructing
/// outbox records directly.
class SyncMutationService {
  final SyncOutboxService outbox;
  final SyncShadowService shadow;

  const SyncMutationService({required this.outbox, required this.shadow});

  Future<void> upsert({
    String? accountId,
    required String collection,
    required String itemId,
    required Map<String, dynamic> payload,
    int? baseEntityRevision,
    Map<String, dynamic>? basePayload,
  }) async {
    final base = accountId == null
        ? null
        : await shadow.get(
            accountId: accountId,
            collection: collection,
            itemId: itemId,
          );
    await outbox.enqueue(
      SyncOutboxRecord.create(
        accountId: accountId,
        collection: collection,
        itemId: itemId,
        operation: SyncOperation.upsert,
        payload: payload,
        baseEntityRevision: baseEntityRevision ?? base?.entityRevision ?? 0,
        basePayload: basePayload ?? base?.payload,
        changedPaths: jsonChangedPaths(basePayload ?? base?.payload, payload),
      ),
    );
  }

  Future<void> delete({
    String? accountId,
    required String collection,
    required String itemId,
    int? baseEntityRevision,
    Map<String, dynamic>? basePayload,
  }) async {
    final base = accountId == null
        ? null
        : await shadow.get(
            accountId: accountId,
            collection: collection,
            itemId: itemId,
          );
    await outbox.enqueue(
      SyncOutboxRecord.create(
        accountId: accountId,
        collection: collection,
        itemId: itemId,
        operation: SyncOperation.delete,
        payload: null,
        baseEntityRevision: baseEntityRevision ?? base?.entityRevision ?? 0,
        basePayload: basePayload ?? base?.payload,
        changedPaths: const [r'$'],
      ),
    );
  }
}
