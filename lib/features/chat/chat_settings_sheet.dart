import 'package:flutter/material.dart';

class ChatSettingsSheet extends StatefulWidget {
  final int answerLength;
  final int knowledgeSource;
  final void Function(int answerLength, int knowledgeSource) onChanged;

  const ChatSettingsSheet({
    super.key,
    required this.answerLength,
    required this.knowledgeSource,
    required this.onChanged,
  });

  @override
  State<ChatSettingsSheet> createState() => _ChatSettingsSheetState();
}

class _ChatSettingsSheetState extends State<ChatSettingsSheet> {
  late int _answerLength;
  late int _knowledgeSource;

  @override
  void initState() {
    super.initState();
    _answerLength = widget.answerLength;
    _knowledgeSource = widget.knowledgeSource;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bottom = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      margin: const EdgeInsets.all(16),
      padding: EdgeInsets.fromLTRB(24, 24, 24, 24 + bottom),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(24),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Chat Settings', style: theme.textTheme.titleMedium),
          const SizedBox(height: 20),
          Text('Answer Length', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: _SettingsChip(
                icon: Icons.short_text_rounded, label: 'Short',
                selected: _answerLength == 0,
                onTap: () => setState(() => _answerLength = 0),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SettingsChip(
                icon: Icons.notes_rounded, label: 'Detailed',
                selected: _answerLength == 1,
                onTap: () => setState(() => _answerLength = 1),
              ),
            ),
          ]),
          const SizedBox(height: 20),
          Text('Knowledge Source', style: theme.textTheme.labelLarge),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: _SettingsChip(
                icon: Icons.library_books_rounded, label: 'Knowledge Base Only',
                selected: _knowledgeSource == 0,
                onTap: () => setState(() => _knowledgeSource = 0),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _SettingsChip(
                icon: Icons.public_rounded, label: 'KB + General',
                selected: _knowledgeSource == 1,
                onTap: () => setState(() => _knowledgeSource = 1),
              ),
            ),
          ]),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: () {
                widget.onChanged(_answerLength, _knowledgeSource);
                Navigator.pop(context);
              },
              child: const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('Apply'),
              ),
            ),
          ),
        ],
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
            Icon(icon, size: 18,
                color: selected ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: selected ? colorScheme.onPrimaryContainer : colorScheme.onSurfaceVariant,
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
