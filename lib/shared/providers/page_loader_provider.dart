import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/services/http_client.dart';
import '../../data/services/headless_webview_page_loader.dart';
import '../../data/services/page_loader.dart';

/// Provides a resilient PageLoader that tries HTTP first, then falls back to
/// headless WebView on failure. This is the primary PageLoader for all content
/// fetching in the app.
final pageLoaderProvider = Provider<PageLoader>((ref) {
  final loader = ResilientPageLoader(
    primary: AppHttpClient(timeout: const Duration(seconds: 10)),
    fallback: HeadlessWebViewPageLoader(
      timeout: const Duration(seconds: 20),
      domWait: const Duration(seconds: 5),
    ),
  );
  ref.onDispose(loader.dispose);
  return loader;
});
