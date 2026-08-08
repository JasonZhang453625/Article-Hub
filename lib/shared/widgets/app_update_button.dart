import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/app_update_provider.dart';
import '../providers/locale_provider.dart';

const _updateGreen = Color(0xFF2E9B62);

/// A compact update entry point that is only visible when a newer release is
/// available (including while its download/install flow is in progress).
class AppUpdateButton extends ConsumerWidget {
  final VoidCallback onPressed;
  final double size;

  const AppUpdateButton({super.key, required this.onPressed, this.size = 40});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appUpdateControllerProvider);
    if (state.check?.updateAvailable != true) {
      return const SizedBox.shrink();
    }

    final s = ref.watch(stringsProvider);
    return IconButton(
      key: const ValueKey('app-update-button'),
      onPressed: onPressed,
      tooltip: s.updateNow,
      padding: EdgeInsets.zero,
      constraints: BoxConstraints.tightFor(width: size, height: size),
      icon: const Icon(Icons.system_update_alt_rounded, color: _updateGreen),
    );
  }
}
