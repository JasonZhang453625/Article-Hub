import 'package:flutter/material.dart';

import '../../data/services/chat_attachment_service.dart';
import '../../shared/utils/locale_strings.dart' show LocaleStrings;

class ChatInputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool loading;
  final LocaleStrings s;
  final VoidCallback onSend;
  final FocusNode? focusNode;
  final List<ChatAttachmentDraft> attachments;
  final ValueChanged<ChatAttachmentDraft>? onRemoveAttachment;

  /// Opens the tools bottom sheet ("+" button).
  final VoidCallback onOpenTools;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.loading,
    required this.s,
    required this.onSend,
    required this.onOpenTools,
    this.focusNode,
    this.attachments = const [],
    this.onRemoveAttachment,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.only(
        left: 16,
        right: 8,
        top: 8,
        // Scaffold's resize-to-avoid-inset already lifts this bar above the
        // keyboard; keep only safe-area clearance (home indicator).
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: Theme.of(context).scaffoldBackgroundColor,
        border: Border(
          top: BorderSide(color: Theme.of(context).dividerColor.withAlpha(40)),
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (attachments.isNotEmpty) ...[
                _ChatAttachmentDrafts(
                  attachments: attachments,
                  removeTooltip: s.chatAttachmentRemove,
                  onRemove: onRemoveAttachment,
                ),
                const SizedBox(height: 8),
              ],
              Row(
                children: [
                  // AI 对话工具页入口：左侧加号打开工具面板。
                  Tooltip(
                    message: s.chatTools,
                    child: InkWell(
                      key: const ValueKey('chat-tools-button'),
                      customBorder: const CircleBorder(),
                      onTap: onOpenTools,
                      child: Container(
                        // Match the filled send button's Material tap target and
                        // visible circle so the input controls align visually.
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: Theme.of(context).colorScheme.surface,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Theme.of(context).dividerColor.withAlpha(60),
                          ),
                        ),
                        child: Transform.translate(
                          offset: const Offset(-2, 0),
                          child: const Icon(
                            Icons.add_rounded,
                            key: ValueKey('chat-tools-plus-icon'),
                            size: 22,
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focusNode,
                      // Auto-growing input: single line initially, expands up to
                      // 5 lines as the user types, then scrolls internally.
                      minLines: 1,
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      decoration: InputDecoration(
                        hintText: s.askHint,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                        filled: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 10,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 4),
                  IconButton.filled(
                    key: const ValueKey('chat-send-button'),
                    onPressed: loading ? null : onSend,
                    icon: loading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.send_rounded),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChatAttachmentDrafts extends StatelessWidget {
  final List<ChatAttachmentDraft> attachments;
  final String removeTooltip;
  final ValueChanged<ChatAttachmentDraft>? onRemove;

  const _ChatAttachmentDrafts({
    required this.attachments,
    required this.removeTooltip,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return SizedBox(
      key: const ValueKey('chat-attachment-drafts'),
      height: 64,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final draft = attachments[index];
          final attachment = draft.attachment;
          return Container(
            key: ValueKey('chat-attachment-draft-${attachment.id}'),
            width: attachment.isImage ? 64 : 176,
            decoration: BoxDecoration(
              color: colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: colorScheme.outlineVariant.withValues(alpha: 0.7),
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                Positioned.fill(
                  child: attachment.isImage
                      ? Image.memory(
                          draft.previewBytes,
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => const Center(
                            child: Icon(Icons.broken_image_outlined),
                          ),
                        )
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(10, 8, 28, 8),
                          child: Row(
                            children: [
                              Icon(
                                Icons.description_outlined,
                                size: 22,
                                color: colorScheme.primary,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  attachment.originalFileName,
                                  maxLines: 2,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context).textTheme.labelSmall,
                                ),
                              ),
                            ],
                          ),
                        ),
                ),
                Positioned(
                  right: 2,
                  top: 2,
                  child: Tooltip(
                    message: removeTooltip,
                    child: InkWell(
                      key: ValueKey('chat-attachment-remove-${attachment.id}'),
                      customBorder: const CircleBorder(),
                      onTap: onRemove == null ? null : () => onRemove!(draft),
                      child: Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: colorScheme.surface.withValues(alpha: 0.9),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.close_rounded, size: 16),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
