import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/folder.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/utils/locale_strings.dart';

class FoldersScreen extends ConsumerStatefulWidget {
  const FoldersScreen({super.key});

  @override
  ConsumerState<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends ConsumerState<FoldersScreen> {
  void _showAddDialog({String? parentId}) {
    final s = ref.read(stringsProvider);
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(parentId == null ? s.newFolder : s.newSubfolder),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(
            labelText: s.folderName,
            hintText: s.folderHint,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              try {
                final folder = Folder(
                  id: const Uuid().v4(),
                  name: name,
                  parentId: parentId,
                );
                await ref.read(foldersProvider.notifier).add(folder);
                if (context.mounted) Navigator.pop(context);
              } catch (e) {
                if (!context.mounted) return;
                final s2 = ref.read(stringsProvider);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${s2.saveFailed}: $e')),
                );
              }
            },
            child: Text(s.create),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(Folder folder) {
    final s = ref.read(stringsProvider);
    final controller = TextEditingController(text: folder.name);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.renameFolder),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(labelText: s.folderName),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () async {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              try {
                await ref.read(foldersProvider.notifier).update(folder.copyWith(name: name));
                if (context.mounted) Navigator.pop(context);
              } catch (e) {
                if (!context.mounted) return;
                final s2 = ref.read(stringsProvider);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${s2.saveFailed}: $e')),
                );
              }
            },
            child: Text(s.rename),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(Folder folder) {
    final s = ref.read(stringsProvider);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.deleteFolder),
        content: Text(s.deleteFolderConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () async {
              try {
                await ref.read(foldersProvider.notifier).delete(folder.id);
                if (context.mounted) Navigator.pop(context);
              } catch (e) {
                if (!context.mounted) return;
                final s2 = ref.read(stringsProvider);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text('${s2.saveFailed}: $e')),
                );
              }
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: Text(s.delete),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final foldersAsync = ref.watch(foldersProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text(s.foldersTitle),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_rounded),
            tooltip: s.newFolder,
            onPressed: () => _showAddDialog(),
          ),
        ],
      ),
      body: foldersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text('Error: $e'),
              ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => ref.invalidate(foldersProvider),
                icon: const Icon(Icons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (folders) {
          if (folders.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_outlined, size: 48, color: theme.colorScheme.outline),
                  const SizedBox(height: 16),
                  Text(s.noFoldersYet, style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 8),
                  Text(
                    s.createFoldersDesc,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
                ],
              ),
            );
          }

          final rootFolders = folders.where((f) => f.parentId == null).toList();

          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 8),
            itemCount: rootFolders.length,
            itemBuilder: (context, index) {
              final folder = rootFolders[index];
              final children = folders.where((f) => f.parentId == folder.id).toList();

              return _FolderTile(
                folder: folder,
                children: children,
                s: s,
                onTap: (folderId) {
                  ref.read(selectedFolderIdProvider.notifier).state = folderId;
                  Navigator.pop(context);
                },
                onRename: () => _showRenameDialog(folder),
                onDelete: () => _confirmDelete(folder),
                onAddSubfolder: () => _showAddDialog(parentId: folder.id),
                onRenameChild: (child) => _showRenameDialog(child),
                onDeleteChild: (child) => _confirmDelete(child),
              );
            },
          );
        },
      ),
    );
  }
}

class _FolderTile extends StatelessWidget {
  final Folder folder;
  final List<Folder> children;
  final LocaleStrings s;
  final ValueChanged<String> onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onAddSubfolder;
  final ValueChanged<Folder> onRenameChild;
  final ValueChanged<Folder> onDeleteChild;

  const _FolderTile({
    required this.folder,
    required this.children,
    required this.s,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
    required this.onAddSubfolder,
    required this.onRenameChild,
    required this.onDeleteChild,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          leading: Icon(Icons.folder_rounded, color: theme.colorScheme.primary),
          title: Text(folder.name, style: const TextStyle(fontWeight: FontWeight.w600)),
          onTap: () => onTap(folder.id),
          trailing: PopupMenuButton<String>(
            onSelected: (value) {
              switch (value) {
                case 'rename':
                  onRename();
                  break;
                case 'delete':
                  onDelete();
                  break;
                case 'add_sub':
                  onAddSubfolder();
                  break;
              }
            },
            itemBuilder: (_) => [
              PopupMenuItem(value: 'add_sub', child: Text(s.addSubfolder)),
              PopupMenuItem(value: 'rename', child: Text(s.rename)),
              PopupMenuItem(value: 'delete', child: Text(s.delete)),
            ],
          ),
        ),
        for (final child in children)
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: ListTile(
              leading: Icon(Icons.folder_outlined, color: theme.colorScheme.primary.withValues(alpha: 0.6)),
              title: Text(child.name),
              onTap: () => onTap(child.id),
              trailing: PopupMenuButton<String>(
                onSelected: (value) {
                  switch (value) {
                    case 'rename':
                      onRenameChild(child);
                      break;
                    case 'delete':
                      onDeleteChild(child);
                      break;
                  }
                },
                itemBuilder: (_) => [
                  PopupMenuItem(value: 'rename', child: Text(s.rename)),
                  PopupMenuItem(value: 'delete', child: Text(s.delete)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
