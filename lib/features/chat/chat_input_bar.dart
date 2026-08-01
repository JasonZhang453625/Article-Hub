import 'package:flutter/material.dart';

import '../../shared/utils/locale_strings.dart' show LocaleStrings;

class ChatInputBar extends StatelessWidget {
  final TextEditingController controller;
  final bool loading;
  final LocaleStrings s;
  final VoidCallback onSend;

  const ChatInputBar({
    super.key,
    required this.controller,
    required this.loading,
    required this.s,
    required this.onSend,
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
          top: BorderSide(
            color: Theme.of(context).dividerColor.withAlpha(40),
          ),
        ),
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: controller,
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
                        horizontal: 20, vertical: 10),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                onPressed: loading ? null : onSend,
                icon: loading
                    ? const SizedBox(
                        width: 20, height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
