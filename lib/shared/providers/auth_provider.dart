import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../config/supabase_config.dart';
import '../../data/services/auth_service.dart';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

/// Subscribes to Supabase auth state changes. Watching this provider causes
/// dependents to rebuild whenever the user signs in or out.
final authStateProvider = StreamProvider<AuthState>((ref) {
  if (!SupabaseConfig.isConfigured) return const Stream.empty();
  return Supabase.instance.client.auth.onAuthStateChange;
});

final currentUserProvider = Provider<User?>((ref) {
  ref.watch(authStateProvider); // re-evaluate on auth changes
  if (!SupabaseConfig.isConfigured) return null;
  return Supabase.instance.client.auth.currentUser;
});

final isLoggedInProvider = Provider<bool>((ref) {
  ref.watch(authStateProvider); // re-evaluate on auth changes
  if (!SupabaseConfig.isConfigured) return false;
  return Supabase.instance.client.auth.currentSession != null;
});

final currentEmailProvider = Provider<String?>((ref) {
  ref.watch(authStateProvider); // re-evaluate on auth changes
  if (!SupabaseConfig.isConfigured) return null;
  return Supabase.instance.client.auth.currentUser?.email;
});
