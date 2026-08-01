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
      _validateLoadedSession(session);
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
    try {
      final refreshed = await _auth.refresh(session);
      if (mounted && _isCurrentSession(session)) {
        state = AsyncValue.data(refreshed);
      }
      return refreshed;
    } on AuthApiException catch (error) {
      if (AuthService.isSessionRejected(error)) {
        await _clearInvalidSession(session);
        return null;
      }
      rethrow;
    }
  }

  Future<void> _validateLoadedSession(AuthSession session) async {
    try {
      final fresh = await _auth.getMe(session);
      if (fresh != null && mounted && _isCurrentSession(session)) {
        state = AsyncValue.data(fresh);
      }
    } on AuthApiException catch (error) {
      if (AuthService.isSessionRejected(error)) {
        await _clearInvalidSession(session);
      }
      // Network errors and unrelated server errors keep the session for
      // offline use; a later API call can retry when connectivity returns.
    } catch (_) {
      // Keep the persisted session for offline use.
    }
  }

  bool _isCurrentSession(AuthSession expected) {
    final current = state.valueOrNull;
    return current?.accessToken == expected.accessToken &&
        current?.refreshToken == expected.refreshToken;
  }

  Future<void> _clearInvalidSession(AuthSession expected) async {
    if (!mounted || !_isCurrentSession(expected)) return;
    await _auth.clearLocalSession();
    if (mounted && _isCurrentSession(expected)) {
      state = const AsyncValue.data(null);
    }
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
