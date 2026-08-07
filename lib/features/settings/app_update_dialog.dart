import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/providers/app_update_provider.dart';
import '../../shared/providers/locale_provider.dart';

class AppUpdateDialog extends ConsumerWidget {
  const AppUpdateDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final s = ref.watch(stringsProvider);
    final state = ref.watch(appUpdateControllerProvider);
    final check = state.check;
    final manifest = check?.manifest;

    return AlertDialog(
      title: Text(s.newVersionAvailable),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (check != null && manifest != null) ...[
              Text('${s.currentVersion}：v${check.currentVersion}'),
              const SizedBox(height: 4),
              Text(
                '${s.latestVersion}：v${manifest.version} · '
                '${_formatBytes(manifest.size)}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              if (manifest.releaseNotes.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  s.releaseNotes,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
                const SizedBox(height: 6),
                ...manifest.releaseNotes.map(
                  (note) => Padding(
                    padding: const EdgeInsets.only(bottom: 4),
                    child: Text('• $note'),
                  ),
                ),
              ],
            ],
            const SizedBox(height: 18),
            _UpdateProgress(state: state),
          ],
        ),
      ),
      actions: _buildActions(context, ref, state),
    );
  }

  List<Widget> _buildActions(
    BuildContext context,
    WidgetRef ref,
    AppUpdateState state,
  ) {
    final s = ref.read(stringsProvider);
    final controller = ref.read(appUpdateControllerProvider.notifier);
    switch (state.phase) {
      case AppUpdatePhase.available:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.later),
          ),
          FilledButton(
            onPressed: controller.startUpdate,
            child: Text(s.updateNow),
          ),
        ];
      case AppUpdatePhase.downloading:
        return [
          TextButton(
            onPressed: () async {
              await controller.cancelUpdate();
              if (context.mounted) Navigator.of(context).pop();
            },
            child: Text(s.cancel),
          ),
        ];
      case AppUpdatePhase.awaitingInstallPermission:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.later),
          ),
          FilledButton(
            onPressed: controller.requestInstallPermission,
            child: Text(s.allowInstall),
          ),
        ];
      case AppUpdatePhase.failed:
        return [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(s.later),
          ),
          FilledButton(onPressed: controller.startUpdate, child: Text(s.retry)),
        ];
      case AppUpdatePhase.verifying:
      case AppUpdatePhase.installing:
      case AppUpdatePhase.idle:
      case AppUpdatePhase.checking:
      case AppUpdatePhase.upToDate:
        return const [];
    }
  }

  static String _formatBytes(int bytes) {
    final mib = bytes / (1024 * 1024);
    return '${mib.toStringAsFixed(1)} MB';
  }
}

class _UpdateProgress extends StatelessWidget {
  final AppUpdateState state;

  const _UpdateProgress({required this.state});

  @override
  Widget build(BuildContext context) {
    final container = ProviderScope.containerOf(context);
    final s = container.read(stringsProvider);
    switch (state.phase) {
      case AppUpdatePhase.downloading:
        final progress = state.downloadProgress;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              progress == null
                  ? s.downloadingUpdate
                  : '${s.downloadingUpdate} ${(progress * 100).round()}%',
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(value: progress),
          ],
        );
      case AppUpdatePhase.verifying:
        return _BusyLabel(label: s.verifyingUpdate);
      case AppUpdatePhase.installing:
        return _BusyLabel(label: s.installingUpdate);
      case AppUpdatePhase.awaitingInstallPermission:
        return Text(s.allowInstallDesc);
      case AppUpdatePhase.failed:
        return Text(
          s.updateFailed,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        );
      case AppUpdatePhase.available:
      case AppUpdatePhase.idle:
      case AppUpdatePhase.checking:
      case AppUpdatePhase.upToDate:
        return const SizedBox.shrink();
    }
  }
}

class _BusyLabel extends StatelessWidget {
  final String label;

  const _BusyLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 10),
        Expanded(child: Text(label)),
      ],
    );
  }
}
