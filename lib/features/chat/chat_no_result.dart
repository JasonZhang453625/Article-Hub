import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/locale_provider.dart';
import '../../data/models/passage.dart';
import 'chat_citation_chips.dart';

class ChatNoResultActions extends ConsumerWidget {
  final String query;
  final List<String> weakArticleIds;
  final List<Article> articles;
  final ValueChanged<String> onSuggestionTap;
  final VoidCallback onBrowseKnowledge;
  final ValueChanged<String> onCitationClick;

  const ChatNoResultActions({
    super.key,
    required this.query,
    required this.weakArticleIds,
    required this.articles,
    required this.onSuggestionTap,
    required this.onBrowseKnowledge,
    required this.onCitationClick,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final s = ref.watch(stringsProvider);

    final terms = _rephraseTerms(query);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (terms.isNotEmpty) ...[
          Text(s.tryBroaderTerm,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8, runSpacing: 6,
            children: [
              for (final term in terms)
                ActionChip(
                  label: Text(term, style: const TextStyle(fontSize: 11)),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                  onPressed: () => onSuggestionTap(term),
                ),
            ],
          ),
          const SizedBox(height: 8),
        ],
        ActionChip(
          avatar: const Icon(Icons.library_books_outlined, size: 14),
          label: Text(s.browseKnowledgeBase, style: const TextStyle(fontSize: 11)),
          onPressed: onBrowseKnowledge,
        ),
        if (weakArticleIds.isNotEmpty) ...[
          const SizedBox(height: 12),
          Text(s.possiblyRelated,
              style: theme.textTheme.labelSmall
                  ?.copyWith(color: colorScheme.onSurfaceVariant)),
          const SizedBox(height: 6),
          CitationChips(
            articleIds: weakArticleIds,
            articles: articles,
            onCitationClick: onCitationClick,
          ),
        ],
      ],
    );
  }

  List<String> _rephraseTerms(String query) {
    final words = query
        .split(RegExp(r'\s+'))
        .map((w) => w.trim())
        .where((w) => w.length > 1)
        .toList();
    final seen = <String>{};
    final unique = <String>[];
    for (final w in words) {
      final key = w.toLowerCase();
      if (seen.add(key)) unique.add(w);
    }
    if (unique.length < 2) return const [];
    return unique.take(4).toList();
  }
}
