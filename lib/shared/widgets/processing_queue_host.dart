import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/ai_providers.dart';
import '../providers/pipeline_provider.dart';

/// Keeps durable article processing awake across asynchronous AI readiness and
/// app lifecycle transitions.
class ProcessingQueueHost extends ConsumerStatefulWidget {
  final Widget child;

  const ProcessingQueueHost({super.key, required this.child});

  @override
  ConsumerState<ProcessingQueueHost> createState() =>
      _ProcessingQueueHostState();
}

class _ProcessingQueueHostState extends ConsumerState<ProcessingQueueHost>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) ref.read(processingQueueProvider).resume();
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
      ref.read(processingQueueProvider).resume();
    }
  }

  @override
  Widget build(BuildContext context) {
    final queue = ref.watch(processingQueueProvider);

    // Hosted gateways are unavailable until /ai/capabilities finishes. Wake
    // the queue when that asynchronous prerequisite becomes ready instead of
    // requiring another settings/auth change or a process restart.
    ref.listen(summaryAiGatewayProvider, (_, next) {
      if (next != null) queue.resume();
    });
    ref.listen(imageUnderstandingServiceProvider, (_, next) {
      if (next != null) queue.resume();
    });

    return widget.child;
  }
}
