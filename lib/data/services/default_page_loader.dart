import 'headless_webview_page_loader.dart';
import 'http_client.dart';
import 'page_loader.dart';

PageLoader createDefaultPageLoader() {
  return ResilientPageLoader(
    primary: AppHttpClient(),
    fallback: HeadlessWebViewPageLoader(),
  );
}
