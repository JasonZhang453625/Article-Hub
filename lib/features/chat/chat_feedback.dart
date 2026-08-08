import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'chat_message.dart';

class ChatFeedbackRow extends StatefulWidget {
  final ChatMessage message;
  final ValueChanged<int> onFeedback;
  final ValueChanged<ChatMessage> onRetry;
  final Future<void> Function(ChatMessage) onSave;
  final String retryLabel;
  final String saveTooltip;
  final String saveSavingLabel;

  const ChatFeedbackRow({
    super.key,
    required this.message,
    required this.onFeedback,
    required this.onRetry,
    required this.onSave,
    required this.retryLabel,
    required this.saveTooltip,
    required this.saveSavingLabel,
  });

  @override
  State<ChatFeedbackRow> createState() => _ChatFeedbackRowState();
}

class _ChatFeedbackRowState extends State<ChatFeedbackRow> {
  int? _localFeedback;
  bool _saving = false;

  int? get _effectiveFeedback => _localFeedback ?? widget.message.feedback;

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      await widget.onSave(widget.message);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _FeedbackButton(
          icon: Icons.thumb_up_outlined,
          activeIcon: Icons.thumb_up_rounded,
          isActive: _effectiveFeedback == 1,
          activeColor: colorScheme.primary,
          onTap: () {
            setState(() => _localFeedback = 1);
            widget.message.feedback = 1;
            widget.onFeedback(1);
          },
        ),
        const SizedBox(width: 4),
        _FeedbackButton(
          icon: Icons.thumb_down_outlined,
          activeIcon: Icons.thumb_down_rounded,
          isActive: _effectiveFeedback == -1,
          activeColor: colorScheme.error,
          onTap: () {
            setState(() => _localFeedback = -1);
            widget.message.feedback = -1;
            widget.onFeedback(-1);
          },
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: widget.saveTooltip,
          child: _FeedbackButton(
            key: ValueKey('chat-save-button-${widget.message.id}'),
            icon: Icons.bookmark_add_outlined,
            activeIcon: Icons.bookmark_added_rounded,
            isActive: false,
            activeColor: colorScheme.primary,
            busy: _saving,
            onTap: _save,
          ),
        ),
        const SizedBox(width: 4),
        Tooltip(
          message: widget.retryLabel,
          child: _FeedbackButton(
            key: ValueKey('chat-retry-button-${widget.message.id}'),
            icon: Icons.refresh_outlined,
            activeIcon: Icons.refresh_rounded,
            isActive: false,
            activeColor: colorScheme.primary,
            onTap: () => widget.onRetry(widget.message),
          ),
        ),
        const SizedBox(width: 4),
        _FeedbackButton(
          icon: Icons.share_outlined,
          activeIcon: Icons.share_rounded,
          isActive: false,
          activeColor: colorScheme.primary,
          onTap: () {
            Share.share(widget.message.text, subject: 'Memora');
          },
        ),
      ],
    );
  }
}

class _FeedbackButton extends StatelessWidget {
  final IconData icon;
  final IconData activeIcon;
  final bool isActive;
  final Color activeColor;
  final VoidCallback onTap;
  final bool busy;

  const _FeedbackButton({
    super.key,
    required this.icon,
    required this.activeIcon,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: isActive || busy ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: busy
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Icon(
                isActive ? activeIcon : icon,
                size: 20,
                color: isActive
                    ? activeColor
                    : Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(
                          150,
                        ),
              ),
      ),
    );
  }
}
