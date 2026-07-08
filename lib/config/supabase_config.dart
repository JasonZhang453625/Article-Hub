import 'package:flutter/foundation.dart';

class SupabaseConfig {
  static const String url = String.fromEnvironment(
    'SUPABASE_URL',
    defaultValue: 'https://bfbokscytzkuppuodpxv.supabase.co',
  );

  static const String _publishableKey = String.fromEnvironment(
    'SUPABASE_PUBLISHABLE_KEY',
    defaultValue: 'sb_publishable_FY5Xb92m6wL67QVxbGOTbw_g_RAwt7i',
  );

  static const String _legacyAnonKey = String.fromEnvironment(
    'SUPABASE_ANON_KEY',
    defaultValue: '',
  );

  static String get publishableKey =>
      _publishableKey.isNotEmpty ? _publishableKey : _legacyAnonKey;

  static bool get isConfigured => url.isNotEmpty && publishableKey.isNotEmpty;

  /// Deep-link redirect URL for email magic-link auth. Must be registered in
  /// the Supabase dashboard (Authentication > URL Configuration > Redirect URLs).
  static const String redirectUrl = 'memora://login-callback';

  static void validate() {
    if (!isConfigured) {
      if (kDebugMode) {
        debugPrint(
          'Supabase not configured. Set SUPABASE_URL and SUPABASE_PUBLISHABLE_KEY via --dart-define.',
        );
      }
    }
  }
}
