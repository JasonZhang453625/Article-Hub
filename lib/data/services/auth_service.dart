import 'package:supabase_flutter/supabase_flutter.dart';
import '../../config/supabase_config.dart';

class AuthService {
  SupabaseClient? get _client {
    if (!SupabaseConfig.isConfigured) return null;
    return Supabase.instance.client;
  }

  bool get isAvailable => _client != null;

  Future<void> sendOtp(String email) async {
    final client = _client;
    if (client == null) throw SupabaseNotConfiguredException();

    await client.auth.signInWithOtp(
      email: email.trim(),
      emailRedirectTo: SupabaseConfig.redirectUrl,
    );
  }

  Future<void> verifyOtp(String email, String token) async {
    final client = _client;
    if (client == null) throw SupabaseNotConfiguredException();

    await client.auth.verifyOTP(
      email: email.trim(),
      token: token.trim(),
      type: OtpType.email,
    );
  }

  Future<void> signOut() async {
    final client = _client;
    if (client == null) throw SupabaseNotConfiguredException();

    await client.auth.signOut();
  }

  Session? get currentSession {
    return _client?.auth.currentSession;
  }

  Stream<AuthState> get onAuthStateChange {
    final client = _client;
    if (client == null) return const Stream.empty();
    return client.auth.onAuthStateChange;
  }
}

class SupabaseNotConfiguredException implements Exception {
  @override
  String toString() => 'Supabase is not configured';
}
