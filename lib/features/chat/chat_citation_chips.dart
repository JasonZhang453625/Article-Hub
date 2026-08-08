import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/routes.dart';
import '../../data/models/passage.dart';

class CitationChips extends StatelessWidget {
  final List<String> articleIds;
  final Map<String, Article> articlesById;
  final ValueChanged<String> onCitationClick;

  const CitationChips({
    super.key,
    required this.articleIds,
    required this.articlesById,
    required this.onCitationClick,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Wrap(
      spacing: 2,
      runSpacing: 0,
      children: articleIds.map((id) {
        final article = articlesById[id];
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
            context.push(AppRoutes.summaryWithId(article.id), extra: article);
          },
        );
      }).toList(),
    );
  }
}

/// Chips for web URLs cited via `[wN]` in a web-fallback answer. Tapping one
/// opens the source in the external browser (the same escape hatch the
/// reader uses for pages the in-app WebView cannot render).
class WebCitationChips extends StatelessWidget {
  final List<String> urls;
  final String? sourceLabel;

  const WebCitationChips({super.key, required this.urls, this.sourceLabel});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 2,
      runSpacing: 0,
      children: urls.map((url) {
        final domain = _domainOf(url);
        return ActionChip(
          avatar: const Icon(Icons.public_rounded, size: 14),
          label: Text(
            domain.isEmpty ? url : domain,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(fontSize: 11),
          ),
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.compact,
          tooltip: url,
          onPressed: () {
            final uri = Uri.tryParse(url);
            if (uri == null || !uri.hasScheme) return;
            launchUrl(uri, mode: LaunchMode.externalApplication);
          },
        );
      }).toList(),
    );
  }

  static String _domainOf(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || uri.host.isEmpty) return url;
    final host = uri.host.replaceFirst(RegExp(r'^www\.'), '');
    return host.split('.').take(2).join('.');
  }
}
