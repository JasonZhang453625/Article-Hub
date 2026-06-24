import 'dart:async';
import 'package:http/http.dart' as http;

/// A response from a single HTTP fetch, reusable by multiple consumers.
class FetchedPage {
  final int statusCode;
  final String? contentType;
  final String body;

  const FetchedPage({
    required this.statusCode,
    this.contentType,
    required this.body,
  });

  bool get isHtml =>
      contentType == null || contentType!.contains('html');
}

/// Shared browser-like headers for all outgoing HTTP requests.
const Map<String, String> _browserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0.0.0 Safari/537.36',
  'Accept':
      'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  'Accept-Encoding': 'gzip, deflate, br',
  'Connection': 'keep-alive',
  'Upgrade-Insecure-Requests': '1',
  'Cache-Control': 'max-age=0',
};

/// Thin wrapper around [http.Client] that injects browser-like headers and
/// returns a reusable [FetchedPage] so metadata + content extraction can share
/// a single network round-trip per URL.
class AppHttpClient {
  final http.Client _client;
  final Duration timeout;

  AppHttpClient({http.Client? client, this.timeout = const Duration(seconds: 10)})
      : _client = client ?? http.Client();

  /// Fetch [url] once and return a [FetchedPage]. Returns null on any error.
  Future<FetchedPage?> fetch(String url) async {
    try {
      final response = await _client
          .get(Uri.parse(url), headers: _browserHeaders)
          .timeout(timeout);

      if (response.statusCode != 200) return null;

      final ct = response.headers['content-type'] ?? '';
      if (!ct.contains('html') && ct.isNotEmpty) return null;

      return FetchedPage(
        statusCode: response.statusCode,
        contentType: ct.isEmpty ? null : ct,
        body: response.body,
      );
    } catch (_) {
      return null;
    }
  }

  void dispose() => _client.close();
}
