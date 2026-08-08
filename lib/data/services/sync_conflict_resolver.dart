import 'sync_apply_service.dart';
import 'sync_conflict_service.dart';
import 'sync_mutation_service.dart';
import 'sync_outbox_service.dart';

/// Applies an explicit user decision and creates a new mutation from the
/// latest remote revision. The original conflicted mutation is never reused,
/// so retrying a resolution remains idempotent and auditable locally.
class SyncConflictResolver {
  final SyncApplyService applier;
  final SyncConflictService conflicts;
  final SyncMutationService mutations;
  final SyncOutboxService outbox;

  const SyncConflictResolver({
    required this.applier,
    required this.conflicts,
    required this.mutations,
    required this.outbox,
  });

  Future<void> keepLocal(SyncConflictRecord conflict) async {
    if (conflict.localDeleted) {
      await applier.applyResolvedDelete(
        collection: conflict.collection,
        itemId: conflict.itemId,
      );
      await mutations.delete(
        accountId: conflict.accountId,
        collection: conflict.collection,
        itemId: conflict.itemId,
        baseEntityRevision: conflict.remoteEntityRevision,
        basePayload: conflict.remotePayload,
      );
    } else {
      final payload = conflict.localPayload;
      if (payload == null) {
        throw const SyncConflictResolutionException(
          'Local conflict payload is missing.',
        );
      }
      await applier.applyResolvedPayload(
        collection: conflict.collection,
        itemId: conflict.itemId,
        payload: payload,
      );
      await mutations.upsert(
        accountId: conflict.accountId,
        collection: conflict.collection,
        itemId: conflict.itemId,
        payload: payload,
        baseEntityRevision: conflict.remoteEntityRevision,
        basePayload: conflict.remotePayload,
      );
    }
    await _finish(conflict);
  }

  Future<void> useRemote(SyncConflictRecord conflict) async {
    if (conflict.remoteDeleted) {
      await applier.applyResolvedDelete(
        collection: conflict.collection,
        itemId: conflict.itemId,
      );
    } else {
      final payload = conflict.remotePayload;
      if (payload == null) {
        throw const SyncConflictResolutionException(
          'Remote conflict payload is missing.',
        );
      }
      await applier.applyResolvedPayload(
        collection: conflict.collection,
        itemId: conflict.itemId,
        payload: payload,
      );
    }
    await _finish(conflict);
  }

  Future<void> _finish(SyncConflictRecord conflict) async {
    await outbox.removeAll([conflict.localMutationId]);
    await conflicts.markResolved(conflict.id);
  }
}

class SyncConflictResolutionException implements Exception {
  final String message;

  const SyncConflictResolutionException(this.message);

  @override
  String toString() => message;
}
