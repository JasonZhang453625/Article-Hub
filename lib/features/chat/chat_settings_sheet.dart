import 'package:flutter/material.dart';
import '../../shared/utils/locale_strings.dart';

class ChatSettingsSheet extends StatefulWidget {
  final LocaleStrings s;
  final int answerLength;
  final int knowledgeSource;
  final Future<void> Function(int answerLength, int knowledgeSource) onChanged;

  const ChatSettingsSheet({
    super.key,
    required this.s,
    required this.answerLength,
    required this.knowledgeSource,
    required this.onChanged,
  });

  @override
  State<ChatSettingsSheet> createState() => _ChatSettingsSheetState();
}

class _ChatSettingsSheetState extends State<ChatSettingsSheet>
    with SingleTickerProviderStateMixin {
  late int _answerLength;
  late int _knowledgeSource;
  bool _applying = false;

  /// Pixels the sheet has been dragged down. Lives in a plain field because
  /// AnimationController values are clamped to [0, 1] and would truncate the
  /// drag distance.
  double _dragOffset = 0;

  /// Drives the snap-back animation when a drag ends below the dismiss
  /// threshold. Its value represents progress back to the resting position.
  late final AnimationController _dragCtrl = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 260),
  )..addListener(_onDragTick);

  double _snapStartOffset = 0;

  @override
  void initState() {
    super.initState();
    _answerLength = widget.answerLength;
    _knowledgeSource = widget.knowledgeSource;
  }

  @override
  void dispose() {
    _dragCtrl.dispose();
    super.dispose();
  }

  void _onDragTick() {
    if (!mounted) return;
    setState(() {
      _dragOffset = _snapStartOffset * (1 - _dragCtrl.value);
    });
  }

  void _onDragUpdate(DragUpdateDetails details) {
    if (_applying) return;
    final next = (_dragOffset + details.delta.dy).clamp(0.0, 1e9);
    if (next != _dragOffset) {
      setState(() => _dragOffset = next);
    }
  }

  void _onDragEnd(DragEndDetails details) {
    if (_applying) return;
    final screenHeight = MediaQuery.sizeOf(context).height;
    final velocity = details.primaryVelocity ?? 0;
    // Fast downward flick or dragged past 20% of the screen: dismiss.
    // Otherwise spring back to the resting position.
    if (velocity > 800 || _dragOffset > screenHeight * 0.2) {
      Navigator.pop(context);
    } else if (_dragOffset > 0) {
      _snapStartOffset = _dragOffset;
      _dragCtrl.forward(from: 0);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    final s = widget.s;

    return Align(
      alignment: Alignment.bottomCenter,
      child: AnimatedBuilder(
        animation: _dragCtrl,
        builder: (context, child) => GestureDetector(
          key: const ValueKey('chat-settings-sheet'),
          // Only the sheet receives drags. Taps above it fall through to the
          // route's dismissible barrier.
          behavior: HitTestBehavior.opaque,
          onVerticalDragStart: (_) => _dragCtrl.stop(),
          onVerticalDragUpdate: _onDragUpdate,
          onVerticalDragEnd: _onDragEnd,
          child: Transform.translate(
            offset: Offset(0, _dragOffset),
            child: SizedBox(
              width: double.infinity,
              height: MediaQuery.sizeOf(context).height * 0.5,
              child: Material(
                color: theme.colorScheme.surfaceContainerLow,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
                clipBehavior: Clip.antiAlias,
                child: SafeArea(
                  top: false,
                  child: SingleChildScrollView(
                    padding: EdgeInsets.fromLTRB(24, 12, 24, 24 + bottom),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Center(
                          child: GestureDetector(
                            key: const ValueKey('chat-settings-handle'),
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragStart: (_) => _dragCtrl.stop(),
                            onVerticalDragUpdate: _onDragUpdate,
                            onVerticalDragEnd: _onDragEnd,
                            child: Container(
                              width: 36,
                              height: 4,
                              margin: const EdgeInsets.only(bottom: 12),
                              decoration: BoxDecoration(
                                color: theme.colorScheme.onSurfaceVariant
                                    .withValues(alpha: 0.4),
                                borderRadius: BorderRadius.circular(2),
                              ),
                            ),
                          ),
                        ),
                        Text(
                          s.chatSettings,
                          style: theme.textTheme.titleMedium,
                        ),
                        const SizedBox(height: 20),
                        Text(
                          s.chatAnswerLength,
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: _SettingsChip(
                                icon: Icons.short_text_rounded,
                                label: s.chatShort,
                                selected: _answerLength == 0,
                                onTap: () => setState(() => _answerLength = 0),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _SettingsChip(
                                icon: Icons.notes_rounded,
                                label: s.chatDetailed,
                                selected: _answerLength == 1,
                                onTap: () => setState(() => _answerLength = 1),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 20),
                        Text(
                          s.chatKnowledgeSource,
                          style: theme.textTheme.labelLarge,
                        ),
                        const SizedBox(height: 8),
                        Row(
                          children: [
                            Expanded(
                              child: _SettingsChip(
                                icon: Icons.library_books_rounded,
                                label: s.chatKnowledgeBaseOnly,
                                selected: _knowledgeSource == 0,
                                onTap: () =>
                                    setState(() => _knowledgeSource = 0),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _SettingsChip(
                                icon: Icons.public_rounded,
                                label: s.chatKbPlusGeneral,
                                selected: _knowledgeSource == 1,
                                onTap: () =>
                                    setState(() => _knowledgeSource = 1),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 24),
                        SizedBox(
                          width: double.infinity,
                          child: FilledButton(
                            onPressed: _applying
                                ? null
                                : () async {
                                    setState(() => _applying = true);
                                    try {
                                      await widget.onChanged(
                                        _answerLength,
                                        _knowledgeSource,
                                      );
                                      if (!context.mounted) return;
                                      Navigator.pop(context);
                                    } finally {
                                      if (mounted) {
                                        setState(() => _applying = false);
                                      }
                                    }
                                  },
                            child: _applying
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 12,
                                    ),
                                    child: Text(s.chatApply),
                                  ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SettingsChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _SettingsChip({
    required this.icon,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 12),
        decoration: BoxDecoration(
          color: selected
              ? colorScheme.primaryContainer
              : colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected
                ? colorScheme.primary
                : colorScheme.outline.withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              icon,
              size: 18,
              color: selected
                  ? colorScheme.onPrimaryContainer
                  : colorScheme.onSurfaceVariant,
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected
                      ? colorScheme.onPrimaryContainer
                      : colorScheme.onSurfaceVariant,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
