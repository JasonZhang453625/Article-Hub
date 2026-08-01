import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/locale_provider.dart';
import '../../shared/utils/url_helpers.dart';

/// Save mode chosen when sharing a URL into the app.
enum ShareSaveMode {
  /// Keep full extracted page body as the knowledge text (no AI summary).
  fullText,

  /// Run the AI summary pipeline (default).
  aiMemory,
}

/// Result returned by [ShareSaveSheet] when the user confirms.
class ShareSaveResult {
  final ShareSaveMode mode;
  final String notes;

  const ShareSaveResult({required this.mode, required this.notes});
}

/// Bottom sheet shown when a URL is shared into the app.
///
/// Lets the user pick [ShareSaveMode] and jot down thoughts (→ [Article.notes]).
class ShareSaveSheet extends ConsumerStatefulWidget {
  final String url;
  final int imageCount;

  const ShareSaveSheet({super.key, required this.url, this.imageCount = 0});

  static Future<ShareSaveResult?> show(BuildContext context, String url) {
    return showModalBottomSheet<ShareSaveResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ShareSaveSheet(url: url),
    );
  }

  static Future<ShareSaveResult?> showImages(
    BuildContext context,
    int imageCount,
  ) {
    return showModalBottomSheet<ShareSaveResult>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => ShareSaveSheet(
        url: 'local-images://selection',
        imageCount: imageCount,
      ),
    );
  }

  @override
  ConsumerState<ShareSaveSheet> createState() => _ShareSaveSheetState();
}

class _ShareSaveSheetState extends ConsumerState<ShareSaveSheet> {
  ShareSaveMode _mode = ShareSaveMode.aiMemory;
  late final TextEditingController _thoughtsController;

  @override
  void initState() {
    super.initState();
    _thoughtsController = TextEditingController();
  }

  @override
  void dispose() {
    _thoughtsController.dispose();
    super.dispose();
  }

  void _submit() {
    Navigator.of(
      context,
    ).pop(ShareSaveResult(mode: _mode, notes: _thoughtsController.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    final domain = widget.imageCount > 0
        ? '${s.selectImages}  ${widget.imageCount}/9'
        : extractDomain(widget.url);

    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: Container(
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                margin: const EdgeInsets.only(bottom: 16),
                decoration: BoxDecoration(
                  color: theme.colorScheme.outline.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
            ),
            Text(s.shareSaveTitle, style: theme.textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              domain,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurface.withValues(alpha: 0.65),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: _ModeCard(
                    selected: _mode == ShareSaveMode.fullText,
                    icon: Icons.article_outlined,
                    title: s.saveModeFullText,
                    description: s.saveModeFullTextDesc,
                    isDark: isDark,
                    onTap: () => setState(() => _mode = ShareSaveMode.fullText),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _ModeCard(
                    selected: _mode == ShareSaveMode.aiMemory,
                    icon: Icons.auto_awesome_rounded,
                    title: s.saveModeAiMemory,
                    description: s.saveModeAiMemoryDesc,
                    isDark: isDark,
                    onTap: () => setState(() => _mode = ShareSaveMode.aiMemory),
                  ),
                ),
              ],
            ),
            if (widget.imageCount > 0) ...[
              const SizedBox(height: 12),
              Text(
                s.imagePrivacyNotice,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.onSurfaceVariant,
                ),
              ),
            ],
            const SizedBox(height: 18),
            Text(s.shareThoughtsLabel, style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              controller: _thoughtsController,
              maxLines: 4,
              minLines: 2,
              textInputAction: TextInputAction.newline,
              decoration: InputDecoration(
                hintText: s.shareThoughtsHint,
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(s.cancel),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: FilledButton.icon(
                    onPressed: _submit,
                    icon: const Icon(Icons.save_rounded),
                    label: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(s.shareSaveAction),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ModeCard extends StatelessWidget {
  final bool selected;
  final IconData icon;
  final String title;
  final String description;
  final bool isDark;
  final VoidCallback onTap;

  const _ModeCard({
    required this.selected,
    required this.icon,
    required this.title,
    required this.description,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final borderColor = selected
        ? primary
        : theme.colorScheme.outline.withValues(alpha: 0.6);
    final bg = selected
        ? primary.withValues(alpha: isDark ? 0.18 : 0.08)
        : theme.colorScheme.surface;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(18),
        child: Ink(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: borderColor, width: selected ? 1.6 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                icon,
                size: 22,
                color: selected ? primary : theme.colorScheme.onSurface,
              ),
              const SizedBox(height: 10),
              Text(
                title,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: selected ? primary : null,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                description,
                style: theme.textTheme.bodySmall?.copyWith(
                  height: 1.3,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
