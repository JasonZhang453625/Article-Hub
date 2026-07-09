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

  bool _running = false;
  DateTime? _lastAttemptAt;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _triggerIfReady();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _triggerIfReady();
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(currentSessionProvider, (previous, next) {
      if (previous?.accessToken != next?.accessToken && next != null) {
        _triggerIfReady();
      }
    });
    ref.listen(connectivityProvider, (previous, next) {
      final wasOnline = previous?.valueOrNull == true;
      final isOnline = next.valueOrNull == true;
      if (!wasOnline && isOnline) {
        _triggerIfReady();
      }
    });
    return widget.child;
  }

  Future<void> _triggerIfReady() async {
    if (!mounted || _running) return;

    final session = ref.read(currentSessionProvider);
    if (session == null) return;

    final online = ref.read(connectivityProvider).valueOrNull ?? true;
    if (!online) return;

    final now = DateTime.now();
    final lastAttemptAt = _lastAttemptAt;
    if (lastAttemptAt != null && now.difference(lastAttemptAt) < _minInterval) {
      return;
    }

    _running = true;
    _lastAttemptAt = now;
    try {
      ref.invalidate(syncNowProvider);
      await ref.read(syncNowProvider.future);
    } catch (_) {
      // Automatic sync must stay silent; the account page exposes manual
      // sync errors where the user can act on them.
    } finally {
      _running = false;
    }
  }
}
