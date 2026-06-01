String cleanUrl(String input) {
  String url = input.trim();
  if (url.isEmpty) return url;

  // Add scheme if missing
  if (!url.startsWith('http://') && !url.startsWith('https://')) {
    url = 'https://$url';
  }

  return url;
}

bool isValidUrl(String url) {
  final uri = Uri.tryParse(url);
  return uri != null &&
      (uri.scheme == 'http' || uri.scheme == 'https') &&
      uri.host.isNotEmpty;
}

String extractDomain(String url) {
  final uri = Uri.tryParse(url);
  if (uri == null) return url;
  return uri.host;
}

/// Parses a free-form block of text containing multiple URLs (separated by
/// newlines, spaces, commas, or semicolons) into a list of valid, normalized,
/// de-duplicated URLs, preserving their first-seen order.
///
/// Each candidate is run through [cleanUrl] (to add a missing scheme) and
/// [isValidUrl]; invalid candidates are dropped.
List<String> parseUrlList(String input) {
  if (input.trim().isEmpty) return const [];

  final candidates = input.split(RegExp(r'[\s,;]+'));
  final seen = <String>{};
  final result = <String>[];

  for (final candidate in candidates) {
    final trimmed = candidate.trim();
    if (trimmed.isEmpty) continue;

    // Require something that actually looks like a URL: either an explicit
    // scheme, or a host containing a dot. This stops bare words (e.g. the
    // pieces of "not a url") from being turned into https://word.
    final hasScheme =
        trimmed.startsWith('http://') || trimmed.startsWith('https://');
    if (!hasScheme && !trimmed.contains('.')) continue;

    final cleaned = cleanUrl(trimmed);
    if (!isValidUrl(cleaned)) continue;

    if (seen.add(cleaned)) {
      result.add(cleaned);
    }
  }

  return result;
}
