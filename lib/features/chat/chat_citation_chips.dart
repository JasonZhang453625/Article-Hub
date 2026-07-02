import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../config/routes.dart';
import '../../data/models/passage.dart';

class CitationChips extends StatelessWidget {
  final List<String> articleIds;
  final List<Article> articles;
  final ValueChanged<String> onCitationClick;

  const CitationChips({
    super.key,
    required this.articleIds,
    required this.articles,
    required this.onCitationClick,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(
      spacing: 2,
      runSpacing: 0,
      children: articleIds.map((id) {
        final article = articles.where((a) => a.id == id).firstOrNull;
        if (article == null) return const SizedBox.shrink();
        final source = article.source;
        return ActionChip(
          avatar: Icon(
            source.icon,
            size: 14,
            color: source.iconColor(isDark: isDark),
          ),
          label: Text(
            article.title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          onPressed: () {
            onCitationClick(article.id);
            context.push(
              AppRoutes.summaryWithId(article.id),
              extra: article,
            );
          },
        );
      }).toList(),
    );
  }
}
