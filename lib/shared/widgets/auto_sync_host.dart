import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import '../providers/sync_providers.dart';

class AutoSyncHost extends ConsumerStatefulWidget {
  final Widget child;

  const AutoSyncHost({super.key, required this.child});

  @override
  ConsumerState<AutoSyncHost> createState() => _AutoSyncHostState();
}

class _AutoSyncHostState extends ConsumerState<AutoSyncHost>
    with WidgetsBindingObserver {
  static const Duration _minInterval = Duration(seconds: 30);
  static const Duration _changeDebounce = Duration(seconds: 2);

  bool _running = false;
  DateTime? _lastAttemptAt;
  Timer? _scheduledSync;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleSync(Duration.zero);
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scheduledSync?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _scheduleSync(Duration.zero);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentSessionProvider, (previous, next) {
      if (previous?.accessToken != next?.accessToken && next != null) {
        _scheduleSync(Duration.zero);
      }
    });
    ref.listen(connectivityProvider, (previous, next) {
      final wasOnline = previous?.valueOrNull == true;
      final isOnline = next.valueOrNull == true;
      if (!wasOnline && isOnline) {
        _scheduleSync(Duration.zero);
      }
    });
    ref.listen(syncOutboxCountProvider, (previous, next) {
      next.whenData((count) {
        if (count > 0 && !_running) {
          _scheduleSync(_changeDebounce);
        }
      });
    });
    return widget.child;
  }

  void _scheduleSync(Duration delay) {
    if (!mounted) return;
    _scheduledSync?.cancel();
    _scheduledSync = Timer(delay, _triggerIfReady);
  }

  Future<void> _triggerIfReady() async {
    if (!mounted || _running) return;

    _running = true;
    try {
      await ref.read(authControllerProvider.notifier).initialLoad;
      if (!mounted) return;

      final session = ref.read(currentSessionProvider);
      if (session == null) return;

      final online = ref.read(connectivityProvider).valueOrNull ?? true;
      if (!online) return;

      final now = DateTime.now();
      final lastAttemptAt = _lastAttemptAt;
      if (lastAttemptAt != null &&
          now.difference(lastAttemptAt) < _minInterval) {
        _scheduleSync(_minInterval - now.difference(lastAttemptAt));
        return;
      }

      _lastAttemptAt = now;
      ref.invalidate(syncNowProvider);
      await ref.read(syncNowProvider.future);
    } catch (_) {
      // Automatic sync must stay silent; the account page exposes manual
      // sync errors where the user can act on them.
    } finally {
      _running = false;
      if (mounted) {
        final accountId = ref.read(currentSessionProvider)?.user.id;
        if (accountId != null) {
          final pending = await ref
              .read(syncOutboxProvider)
              .count(accountId: accountId);
          if (pending > 0) _scheduleSync(_minInterval);
        }
      }
    }
  }
}
