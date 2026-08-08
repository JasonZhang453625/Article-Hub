import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/services/auth_service.dart';

final authServiceProvider = Provider<AuthService>((ref) => AuthService());

final authControllerProvider =
    StateNotifierProvider<AuthController, AsyncValue<AuthSession?>>((ref) {
      return AuthController(ref.read(authServiceProvider));
    });

class AuthController extends StateNotifier<AsyncValue<AuthSession?>> {
  final AuthService _auth;
  final Completer<void> _initialLoad = Completer<void>();
  Future<AuthSession?>? _refreshInFlight;
  String? _refreshTokenInFlight;
  int? _refreshGenerationInFlight;
  int _sessionGeneration = 0;

  AuthController(this._auth) : super(const AsyncValue.loading()) {
    _load();
  }

  /// Completes after the persisted session has been loaded and validated.
  /// Startup jobs must await this before using the session so they cannot race
  /// the first refresh after an app update.
  Future<void> get initialLoad => _initialLoad.future;

  Future<void> _load() async {
    final generation = _sessionGeneration;
    try {
      final session = await _auth.loadSession();
      if (!mounted || generation != _sessionGeneration) return;
      if (session == null) {
        state = const AsyncValue.data(null);
        return;
      }
      state = AsyncValue.data(session);
      await _validateLoadedSession(session, generation);
    } catch (e, st) {
      if (mounted && generation == _sessionGeneration) {
        state = AsyncValue.error(e, st);
      }
    } finally {
      if (!_initialLoad.isCompleted) _initialLoad.complete();
    }
  }

  Future<void> sendOtp(String email) => _auth.sendOtp(email);

  Future<void> verifyOtp(String email, String token) async {
    final generation = _beginSessionChange();
    state = const AsyncValue.loading();
    try {
      final session = await _auth.verifyOtp(email, token);
      if (mounted && generation == _sessionGeneration) {
        state = AsyncValue.data(session);
      }
    } catch (e, st) {
      if (mounted && generation == _sessionGeneration) {
        state = AsyncValue.error(e, st);
      }
      rethrow;
    }
  }

  Future<void> signOut() async {
    final session = state.valueOrNull;
    _beginSessionChange();
    state = const AsyncValue.data(null);
    await _auth.signOut(session);
  }

  Future<AuthSession?> refresh() {
    final session = state.valueOrNull;
    if (session == null) return Future<AuthSession?>.value(null);
    final generation = _sessionGeneration;
    final inFlight = _refreshInFlight;
    if (inFlight != null &&
        _refreshGenerationInFlight == generation &&
        _refreshTokenInFlight == session.refreshToken) {
      return inFlight;
    }

    late final Future<AuthSession?> tracked;
    tracked = _refreshOnce(session, generation).whenComplete(() {
      if (identical(_refreshInFlight, tracked)) {
        _refreshInFlight = null;
        _refreshTokenInFlight = null;
        _refreshGenerationInFlight = null;
      }
    });
    _refreshInFlight = tracked;
    _refreshTokenInFlight = session.refreshToken;
    _refreshGenerationInFlight = generation;
    return tracked;
  }

  Future<AuthSession?> _refreshOnce(AuthSession session, int generation) async {
    try {
      final refreshed = await _auth.refresh(session);
      if (!mounted ||
          generation != _sessionGeneration ||
          !_isCurrentSession(session)) {
        return null;
      }
      state = AsyncValue.data(refreshed);
      return refreshed;
    } on AuthSessionChangedException {
      return null;
    } on AuthApiException catch (error) {
      if (AuthService.isSessionRejected(error)) {
        await _clearInvalidSession(session, generation);
        return null;
      }
      rethrow;
    }
  }

  Future<void> _validateLoadedSession(
    AuthSession session,
    int generation,
  ) async {
    try {
      final fresh = await _auth.getMe(session);
      if (fresh != null &&
          mounted &&
          generation == _sessionGeneration &&
          _isCurrentSession(session)) {
        state = AsyncValue.data(fresh);
      }
    } on AuthApiException catch (error) {
      if (AuthService.isSessionRejected(error)) {
        await _clearInvalidSession(session, generation);
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

  int _beginSessionChange() {
    _sessionGeneration += 1;
    _refreshInFlight = null;
    _refreshTokenInFlight = null;
    _refreshGenerationInFlight = null;
    return _sessionGeneration;
  }

  Future<void> _clearInvalidSession(
    AuthSession expected,
    int generation,
  ) async {
    if (!mounted ||
        generation != _sessionGeneration ||
        !_isCurrentSession(expected)) {
      return;
    }
    _beginSessionChange();
    state = const AsyncValue.data(null);
    await _auth.clearLocalSession();
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
