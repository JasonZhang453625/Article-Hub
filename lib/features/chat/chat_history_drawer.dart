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
  final Future<void> Function(String threadId, String title) onRenameThread;
  final Future<void> Function(String threadId, bool isPinned) onSetThreadPinned;

  const ChatHistoryDrawer({
    super.key,
    required this.threads,
    required this.activeThreadId,
    required this.s,
    required this.enabled,
    required this.onNewThread,
    required this.onSelectThread,
    required this.onDeleteThread,
    required this.onRenameThread,
    required this.onSetThreadPinned,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final screenWidth = MediaQuery.sizeOf(context).width;

    return Drawer(
      width: screenWidth < 420 ? screenWidth * 0.86 : 360,
      backgroundColor: theme.colorScheme.surfaceContainerLow,
      // The Drawer's Material does not clip when no shape is set; clip the
      // whole surface so scrolled list content can never paint outside it.
      clipBehavior: Clip.hardEdge,
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Opaque header: the thread list scrolls *under* the
            // new-chat button, never over it.
            ColoredBox(
              color: theme.colorScheme.surfaceContainerLow,
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
                          key: const ValueKey('chat-sidebar-close-button'),
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
                      onPressed: enabled
                          ? () => _startNewThread(context)
                          : null,
                      icon: const Icon(Icons.add_comment_outlined),
                      label: Text(s.chatNew),
                    ),
                  ),
                  const SizedBox(height: 6),
                ],
              ),
            ),
            Expanded(
              child: ClipRect(
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
                    : ScrollConfiguration(
                        behavior: ScrollConfiguration.of(
                          context,
                        ).copyWith(overscroll: false),
                        child: ListView.builder(
                          key: const ValueKey('chat-thread-list'),
                          clipBehavior: Clip.hardEdge,
                          physics: const ClampingScrollPhysics(),
                          padding: const EdgeInsets.symmetric(vertical: 4),
                          itemCount: threads.length,
                          itemBuilder: (context, index) {
                            final thread = threads[index];
                            final isActive = thread.id == activeThreadId;
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 1,
                              ),
                              child: ListTile(
                                key: ValueKey('chat-thread-${thread.id}'),
                                dense: true,
                                visualDensity: const VisualDensity(
                                  vertical: -1,
                                ),
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
                                title: Row(
                                  children: [
                                    Expanded(
                                      child: Text(
                                        thread.title,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    if (thread.isPinned) ...[
                                      const SizedBox(width: 6),
                                      Icon(
                                        Icons.push_pin_rounded,
                                        key: ValueKey(
                                          'chat-thread-pin-${thread.id}',
                                        ),
                                        size: 16,
                                        color: theme.colorScheme.primary,
                                      ),
                                    ],
                                  ],
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
                                  icon: const Icon(
                                    Icons.delete_outline_rounded,
                                  ),
                                  onPressed: enabled
                                      ? () => _confirmDelete(context, thread)
                                      : null,
                                ),
                                onTap: enabled
                                    ? () => _selectThread(context, thread.id)
                                    : null,
                                onLongPress: enabled
                                    ? () => _showThreadActions(context, thread)
                                    : null,
                              ),
                            );
                          },
                        ),
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showThreadActions(
    BuildContext context,
    ChatThread thread,
  ) async {
    final action = await showModalBottomSheet<_ChatThreadAction>(
      context: context,
      useSafeArea: true,
      builder: (sheetContext) => Wrap(
        children: [
          ListTile(
            key: const ValueKey('chat-thread-rename-action'),
            leading: const Icon(Icons.edit_outlined),
            title: Text(s.rename),
            onTap: () => Navigator.pop(sheetContext, _ChatThreadAction.rename),
          ),
          ListTile(
            key: const ValueKey('chat-thread-pin-action'),
            leading: Icon(
              thread.isPinned
                  ? Icons.push_pin_outlined
                  : Icons.push_pin_rounded,
            ),
            title: Text(thread.isPinned ? s.chatUnpin : s.chatPin),
            onTap: () =>
                Navigator.pop(sheetContext, _ChatThreadAction.togglePin),
          ),
        ],
      ),
    );
    if (!context.mounted || action == null) return;
    switch (action) {
      case _ChatThreadAction.rename:
        await _renameThread(context, thread);
        break;
      case _ChatThreadAction.togglePin:
        await onSetThreadPinned(thread.id, !thread.isPinned);
        break;
    }
  }

  Future<void> _renameThread(BuildContext context, ChatThread thread) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _RenameChatThreadDialog(initialTitle: thread.title, s: s),
    );
    final normalized = title?.trim() ?? '';
    if (normalized.isNotEmpty) {
      await onRenameThread(thread.id, normalized);
    }
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

enum _ChatThreadAction { rename, togglePin }

class _RenameChatThreadDialog extends StatefulWidget {
  final String initialTitle;
  final LocaleStrings s;

  const _RenameChatThreadDialog({required this.initialTitle, required this.s});

  @override
  State<_RenameChatThreadDialog> createState() =>
      _RenameChatThreadDialogState();
}

class _RenameChatThreadDialogState extends State<_RenameChatThreadDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle)
      ..selection = TextSelection(
        baseOffset: 0,
        extentOffset: widget.initialTitle.length,
      );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.s.rename),
      content: TextField(
        key: const ValueKey('chat-thread-rename-field'),
        controller: _controller,
        autofocus: true,
        maxLength: 64,
        textInputAction: TextInputAction.done,
        onSubmitted: (value) => Navigator.pop(context, value),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(widget.s.cancel),
        ),
        FilledButton(
          key: const ValueKey('chat-thread-rename-confirm'),
          onPressed: () => Navigator.pop(context, _controller.text),
          child: Text(widget.s.rename),
        ),
      ],
    );
  }
}
