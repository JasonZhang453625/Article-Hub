import 'package:flutter/material.dart';

import '../../data/models/chat_thread.dart';
import '../../shared/utils/locale_strings.dart';

class ChatHistoryDrawer extends StatelessWidget {
  final List<ChatThread> threads;
  final String? activeThreadId;
  final LocaleStrings s;
  final bool enabled;
  final Future<void> Function() onNewThread;
  final Future<void> Function(String threadId) onSelectThread;
  final Future<void> Function(String threadId) onDeleteThread;

  const ChatHistoryDrawer({
    super.key,
    required this.threads,
    required this.activeThreadId,
    required this.s,
    required this.enabled,
    required this.onNewThread,
    required this.onSelectThread,
    required this.onDeleteThread,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;

    return Drawer(
      width: screenWidth < 420 ? screenWidth * 0.86 : 360,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      s.chatHistory,
                      style: theme.textTheme.titleLarge,
                    ),
                  ),
                  IconButton(
                    tooltip: MaterialLocalizations.of(
                      context,
                    ).closeButtonTooltip,
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close_rounded),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: FilledButton.tonalIcon(
                key: const ValueKey('chat-new-thread-button'),
                onPressed: enabled ? () => _startNewThread(context) : null,
                icon: const Icon(Icons.add_comment_outlined),
                label: Text(s.chatNew),
              ),
            ),
            const SizedBox(height: 12),
            const Divider(height: 1),
            Expanded(
              child: threads.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          s.chatNoHistory,
                          textAlign: TextAlign.center,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: threads.length,
                      itemBuilder: (context, index) {
                        final thread = threads[index];
                        final isActive = thread.id == activeThreadId;
                        return Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          child: ListTile(
                            key: ValueKey('chat-thread-${thread.id}'),
                            selected: isActive,
                            selectedTileColor:
                                theme.colorScheme.secondaryContainer,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            leading: Icon(
                              isActive
                                  ? Icons.chat_rounded
                                  : Icons.chat_bubble_outline_rounded,
                            ),
                            title: Text(
                              thread.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            subtitle: thread.lastMessagePreview.isEmpty
                                ? null
                                : Text(
                                    thread.lastMessagePreview,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                            trailing: IconButton(
                              tooltip: s.chatDelete,
                              icon: const Icon(Icons.delete_outline_rounded),
                              onPressed: enabled
                                  ? () => _confirmDelete(context, thread)
                                  : null,
                            ),
                            onTap: enabled
                                ? () => _selectThread(context, thread.id)
                                : null,
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startNewThread(BuildContext context) async {
    await onNewThread();
    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _selectThread(BuildContext context, String threadId) async {
    await onSelectThread(threadId);
    if (context.mounted) Navigator.pop(context);
  }

  Future<void> _confirmDelete(BuildContext context, ChatThread thread) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(s.chatDelete),
        content: Text(s.chatDeleteConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(s.delete),
          ),
        ],
      ),
    );
    if (confirmed == true) await onDeleteThread(thread.id);
  }
}
