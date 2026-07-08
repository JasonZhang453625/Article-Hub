import 'package:flutter/foundation.dart';

class SupabaseConfig {
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: '',
  );

  static const String publishableKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;

  /// Deep-link redirect URL for email magic-link auth. Must be registered in
  /// the Supabase dashboard (Authentication > URL Configuration > Redirect URLs).
  static const String redirectUrl = 'memora://login-callback';

  static void validate() {
    if (!isConfigured) {
      if (kDebugMode) {
        debugPrint('Supabase not configured. Set SUPABASE_URL and SUPABASE_ANON_KEY via --dart-define.');
      }
    }
  }
}
