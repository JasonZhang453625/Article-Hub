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
  if (uri == null) return false;
  if (uri.scheme != 'http' && uri.scheme != 'https') return false;
  if (uri.host.isEmpty) return false;

  // Host must contain at least one dot (e.g. "example.com")
  if (!uri.host.contains('.')) return false;

  // Reject hosts that are mostly percent-encoded (not real domains)
  final percentCount = '%'.allMatches(uri.host).length;
  if (percentCount > 2) return false;

  // TLD must be at least 2 chars and alphabetic
  final parts = uri.host.split('.');
  final tld = parts.last;
  if (tld.length < 2 || !RegExp(r'^[a-zA-Z]+$').hasMatch(tld)) return false;

  return true;
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
