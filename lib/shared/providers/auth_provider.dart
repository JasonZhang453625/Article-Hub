import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/auth_service.dart';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

final authControllerProvider =
    StateNotifierProvider<AuthController, AsyncValue<AuthSession?>>((ref) {
      return AuthController(ref.read(authServiceProvider));
    });

class AuthController extends StateNotifier<AsyncValue<AuthSession?>> {
  final AuthService _auth;

  AuthController(this._auth) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    try {
      final session = await _auth.loadSession();
      if (session == null) {
        state = const AsyncValue.data(null);
        return;
      }
      state = AsyncValue.data(session);
      _auth
          .getMe(session)
          .then((fresh) {
            if (fresh != null && mounted) state = AsyncValue.data(fresh);
          })
          .catchError((_) {
            // Keep the persisted session for offline use; API calls can refresh
            // later when the network is available.
          });
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> sendOtp(String email) => _auth.sendOtp(email);

  Future<void> verifyOtp(String email, String token) async {
    state = const AsyncValue.loading();
    try {
      final session = await _auth.verifyOtp(email, token);
      state = AsyncValue.data(session);
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      rethrow;
    }
  }

  Future<void> signOut() async {
    final session = state.valueOrNull;
    await _auth.signOut(session);
    state = const AsyncValue.data(null);
  }

  Future<AuthSession?> refresh() async {
    final session = state.valueOrNull;
    if (session == null) return null;
    final refreshed = await _auth.refresh(session);
    state = AsyncValue.data(refreshed);
    return refreshed;
  }
}

final currentUserProvider = Provider<AuthUser?>((ref) {
  return ref.watch(authControllerProvider).valueOrNull?.user;
});

final currentSessionProvider = Provider<AuthSession?>((ref) {
  return ref.watch(authControllerProvider).valueOrNull;
});

final isLoggedInProvider = Provider<bool>((ref) {
  return ref.watch(currentSessionProvider) != null;
});

final currentEmailProvider = Provider<String?>((ref) {
  return ref.watch(currentUserProvider)?.email;
});
