import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/sync_conflict_service.dart';
import '../../shared/providers/article_providers.dart';
import '../../shared/providers/filter_providers.dart';
import '../../shared/providers/folder_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/providers/sync_providers.dart';

class SyncConflictsScreen extends ConsumerWidget {
  const SyncConflictsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final conflicts = ref.watch(syncConflictsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('同步冲突')),
      body: conflicts.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(child: Text('读取冲突失败：$error')),
        data: (items) {
          if (items.isEmpty) {
            return const Center(child: Text('没有待处理的冲突'));
          }
          return ListView.separated(
            padding: const EdgeInsets.all(16),
            itemCount: items.length,
            separatorBuilder: (_, _) => const SizedBox(height: 12),
            itemBuilder: (context, index) => _ConflictCard(
              conflict: items[index],
              onResolved: () => _refresh(ref, items[index]),
            ),
          );
        },
      ),
    );
  }

  void _refresh(WidgetRef ref, SyncConflictRecord conflict) {
    ref.invalidate(syncConflictsProvider);
    ref.invalidate(syncConflictCountProvider);
    switch (conflict.collection) {
      case 'articles':
        ref.invalidate(articlesProvider);
        ref.invalidate(articleRepositoryProvider);
        return;
      case 'folders':
        ref.invalidate(foldersProvider);
        return;
      case 'filter_groups':
        ref.invalidate(filterGroupsProvider);
        return;
      case 'app_settings':
        ref.invalidate(settingsProvider);
        return;
    }
  }
}

class _ConflictCard extends ConsumerStatefulWidget {
  final SyncConflictRecord conflict;
  final VoidCallback onResolved;

  const _ConflictCard({required this.conflict, required this.onResolved});

  @override
  ConsumerState<_ConflictCard> createState() => _ConflictCardState();
}

class _ConflictCardState extends ConsumerState<_ConflictCard> {
  bool _working = false;

  @override
  Widget build(BuildContext context) {
    final conflict = widget.conflict;
    final theme = Theme.of(context);
    final title = _displayName(conflict);
    final paths = conflict.conflictPaths.isEmpty
        ? '整条记录'
        : conflict.conflictPaths.join('、');

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Text(
              '${conflict.collection} · ${conflict.itemId}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 4),
            Text('冲突字段：$paths', style: theme.textTheme.bodySmall),
            Text(
              '云端版本 ${conflict.remoteEntityRevision}，本地基于 ${conflict.baseEntityRevision}',
              style: theme.textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: _working
                        ? null
                        : () => _resolve(keepLocal: true),
                    child: const Text('保留本地'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilledButton(
                    onPressed: _working
                        ? null
                        : () => _resolve(keepLocal: false),
                    child: const Text('使用云端'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _resolve({required bool keepLocal}) async {
    setState(() => _working = true);
    try {
      final resolver = ref.read(syncConflictResolverProvider);
      if (keepLocal) {
        await resolver.keepLocal(widget.conflict);
      } else {
        await resolver.useRemote(widget.conflict);
      }
      widget.onResolved();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(keepLocal ? '已保留本地版本' : '已使用云端版本')),
        );
      }
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('处理失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  String _displayName(SyncConflictRecord conflict) {
    for (final payload in [conflict.localPayload, conflict.remotePayload]) {
      final value = payload?['title'] ?? payload?['name'];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return conflict.itemId;
  }
}
