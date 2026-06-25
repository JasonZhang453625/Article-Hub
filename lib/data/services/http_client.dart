import 'dart:async';
import 'dart:convert' show utf8, latin1;
import 'dart:developer' as developer;
import 'package:http/http.dart' as http;
import 'package:charset/charset.dart';

import 'page_loader.dart';

export 'page_loader.dart' show FetchedPage, PageLoadSource, PageLoader;

/// Shared browser-like headers for all outgoing HTTP requests.
const Map<String, String> _browserHeaders = {
  'User-Agent':
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/124.0.0.0 Safari/537.36',
  'Accept':
      'text/html,application/xhtml+xml,application/xml;q=0.9,image/webp,*/*;q=0.8',
  'Accept-Language': 'zh-CN,zh;q=0.9,en;q=0.8',
  'Connection': 'keep-alive',
  'Upgrade-Insecure-Requests': '1',
  'Cache-Control': 'max-age=0',
};

/// Thin wrapper around [http.Client] that injects browser-like headers and
/// returns a reusable [FetchedPage] so metadata + content extraction can share
/// a single network round-trip per URL.
class AppHttpClient implements PageLoader {
  final http.Client _client;
  final Duration timeout;

  AppHttpClient({http.Client? client, this.timeout = const Duration(seconds: 10)})
      : _client = client ?? http.Client();

  /// Fetch [url] once and return a [FetchedPage]. Returns null on any error.
  @override
  Future<FetchedPage?> fetch(String url) async {
    try {
      final response = await _client
          .get(Uri.parse(url), headers: _browserHeaders)
          .timeout(timeout);

      if (response.statusCode != 200) {
        developer.log(
          'non-200 status: ${response.statusCode}, url: $url',
          name: 'article_hub.http',
        );
        return null;
      }

      final ct = response.headers['content-type'] ?? '';
      if (!ct.contains('html') && ct.isNotEmpty) {
        developer.log(
          'non-HTML content-type: $ct, url: $url',
          name: 'article_hub.http',
        );
        return null;
      }

      final body = _decodeBody(response);

      return FetchedPage(
        statusCode: response.statusCode,
        contentType: ct.isEmpty ? null : ct,
        body: body,
        finalUrl: response.request?.url.toString() ?? url,
        source: PageLoadSource.http,
      );
    } on TimeoutException {
      developer.log('timeout ($timeout), url: $url', name: 'article_hub.http');
      return null;
    } catch (e) {
      developer.log('fetch error: $e, url: $url', name: 'article_hub.http');
      return null;
    }
  }

  @override
  void dispose() => _client.close();

  String _decodeBody(http.Response response) {
    final ct = response.headers['content-type'] ?? '';
    final bytes = response.bodyBytes;

    // 1. Check HTTP Content-Type header for charset.
    var charset = _extractCharset(ct);

    // 2. If not in header, check HTML <meta> tags (first 2048 bytes).
    if (charset == null) {
      final head = latin1.decode(bytes.sublist(0, bytes.length.clamp(0, 2048)));
      charset = _extractCharset(head);
    }

    // 3. Decode with detected charset.
    if (charset != null) {
      return _decodeWithCharset(bytes, charset);
    }

    // 4. Default: try UTF-8, fall back to latin1.
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }

  String? _extractCharset(String text) {
    // Match Content-Type charset: charset=xxx or charset="xxx"
    final m1 = RegExp(r'charset=["\x27]?([^\s;"\x27]+)', caseSensitive: false).firstMatch(text);
    if (m1 != null) return m1.group(1)!.toLowerCase().replaceAll('"', '').replaceAll("'", '');

    // Match <meta charset="xxx">
    final m2 = RegExp(r'<meta[^>]+charset=["\x27]?([^\s;"\x27>]+)', caseSensitive: false).firstMatch(text);
    if (m2 != null) return m2.group(1)!.toLowerCase().replaceAll('"', '').replaceAll("'", '');

    return null;
  }

  String _decodeWithCharset(List<int> bytes, String charset) {
    // Normalize charset aliases.
    final normalized = charset
        .replaceAll(RegExp(r'[-_]'), '')
        .replaceAll('windows1252', 'latin1')
        .replaceAll('iso88591', 'latin1');

    // GBK / GB2312 / GB18030 — all use the charset package.
    if (normalized.contains('gbk') || normalized.contains('gb2312') || normalized.contains('gb18030')) {
      try {
        return gbk.decode(bytes);
      } catch (_) {}
    }

    // Big5 (Traditional Chinese) — not in charset package, try UTF-8 fallback.

    // Shift_JIS (Japanese).
    if (normalized.contains('shiftjis') || normalized.contains('sjis')) {
      try {
        return shiftJis.decode(bytes);
      } catch (_) {}
    }

    // EUC-KR (Korean).
    if (normalized.contains('euckr')) {
      try {
        return eucKr.decode(bytes);
      } catch (_) {}
    }

    // UTF-8 variants.
    if (normalized.contains('utf8')) {
      try {
        return utf8.decode(bytes);
      } catch (_) {}
    }

    // Everything else (latin1, iso-8859-x, windows-125x): try UTF-8 first,
    // fall back to latin1 (byte-transparent).
    try {
      return utf8.decode(bytes);
    } catch (_) {
      return latin1.decode(bytes);
    }
  }
}
