import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/folder.dart';
import '../../shared/providers/passage_providers.dart';

class FoldersScreen extends ConsumerStatefulWidget {
  const FoldersScreen({super.key});

  @override
  ConsumerState<FoldersScreen> createState() => _FoldersScreenState();
}

class _FoldersScreenState extends ConsumerState<FoldersScreen> {
  void _showAddDialog({String? parentId}) {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(parentId == null ? 'New Folder' : 'New Subfolder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Folder name',
            hintText: 'e.g. Tech, Reading List',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              final folder = Folder(
                id: const Uuid().v4(),
                name: name,
                parentId: parentId,
              );
              ref.read(foldersProvider.notifier).add(folder);
              Navigator.pop(context);
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
  }

  void _showRenameDialog(Folder folder) {
    final controller = TextEditingController(text: folder.name);
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Rename Folder'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Folder name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final name = controller.text.trim();
              if (name.isEmpty) return;
              ref.read(foldersProvider.notifier).update(folder.copyWith(name: name));
              Navigator.pop(context);
            },
            child: const Text('Rename'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(Folder folder) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Folder'),
        content: Text(
          'Delete "${folder.name}"? Articles in this folder will become unfiled.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              ref.read(foldersProvider.notifier).delete(folder.id);
              Navigator.pop(context);
            },
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final foldersAsync = ref.watch(foldersProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Folders'),
        actions: [
          IconButton(
            icon: const Icon(Icons.create_new_folder_rounded),
            tooltip: 'New folder',
            onPressed: () => _showAddDialog(),
          ),
        ],
      ),
      body: foldersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (folders) {
          if (folders.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.folder_outlined, size: 48, color: theme.colorScheme.outline),
                  const SizedBox(height: 16),
                  Text('No folders yet', style: theme.textTheme.bodyLarge),
                  const SizedBox(height: 8),
                  Text(
                    'Create folders to organize your articles',
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
  final VoidCallback onRename;
  final VoidCallback onDelete;
  final VoidCallback onAddSubfolder;
  final ValueChanged<Folder> onRenameChild;
  final ValueChanged<Folder> onDeleteChild;

  const _FolderTile({
    required this.folder,
    required this.children,
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
              const PopupMenuItem(value: 'add_sub', child: Text('Add subfolder')),
              const PopupMenuItem(value: 'rename', child: Text('Rename')),
              const PopupMenuItem(value: 'delete', child: Text('Delete')),
            ],
          ),
        ),
        for (final child in children)
          Padding(
            padding: const EdgeInsets.only(left: 32),
            child: ListTile(
              leading: Icon(Icons.folder_outlined, color: theme.colorScheme.primary.withValues(alpha: 0.6)),
              title: Text(child.name),
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
                  const PopupMenuItem(value: 'rename', child: Text('Rename')),
                  const PopupMenuItem(value: 'delete', child: Text('Delete')),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
