import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_update_provider.dart';

/// Performs one silent update check for each app process and keeps the
/// installer flow alive when the app returns from Android's permission page.
class AppUpdateHost extends ConsumerStatefulWidget {
  final Widget child;

  const AppUpdateHost({super.key, required this.child});

  @override
  ConsumerState<AppUpdateHost> createState() => _AppUpdateHostState();
}

class _AppUpdateHostState extends ConsumerState<AppUpdateHost>
    with WidgetsBindingObserver {
  bool _checkStarted = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _checkStarted) return;
      _checkStarted = true;
      unawaited(
        ref.read(appUpdateControllerProvider.notifier).checkForUpdate(),
      );
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
      unawaited(
        ref.read(appUpdateControllerProvider.notifier).handleAppResumed(),
      );
    }
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
