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
