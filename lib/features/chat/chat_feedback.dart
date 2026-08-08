import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'chat_message.dart';

class ChatFeedbackRow extends StatefulWidget {
  final ChatMessage message;
  final ValueChanged<int> onFeedback;
  final ValueChanged<ChatMessage> onRetry;
  final String retryLabel;

  const ChatFeedbackRow({
    super.key,
    required this.message,
    required this.onFeedback,
    required this.onRetry,
    required this.retryLabel,
  });

  @override
  State<ChatFeedbackRow> createState() => _ChatFeedbackRowState();
}

class _ChatFeedbackRowState extends State<ChatFeedbackRow> {
  int? _localFeedback;

  int? get _effectiveFeedback => _localFeedback ?? widget.message.feedback;

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

  const _FeedbackButton({
    super.key,
    required this.icon,
    required this.activeIcon,
    required this.isActive,
    required this.activeColor,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: isActive ? null : onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(
          isActive ? activeIcon : icon,
          size: 20,
          color: isActive
              ? activeColor
              : Theme.of(context).colorScheme.onSurfaceVariant.withAlpha(150),
        ),
      ),
    );
  }
}
