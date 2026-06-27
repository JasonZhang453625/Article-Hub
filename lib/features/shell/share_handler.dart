import 'dart:async';
import 'dart:io' show File, Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:receive_sharing_intent/receive_sharing_intent.dart';
import 'package:uuid/uuid.dart';

import '../../data/models/passage.dart';
import '../../data/models/source_platform.dart';
import '../../data/services/backup_service.dart';
import '../../data/services/processing_pipeline.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/url_helpers.dart';

/// Handles share intents (URLs, backup files) received from other apps.
///
/// Must be placed inside a Material widget tree so [ScaffoldMessenger] is
/// available for SnackBars. It's a pass-through wrapper: [build] returns the
/// child unchanged.
class ShareHandler extends ConsumerStatefulWidget {
  final Widget child;

  const ShareHandler({super.key, required this.child});

  @override
  ConsumerState<ShareHandler> createState() => _ShareHandlerState();
}

class _ShareHandlerState extends ConsumerState<ShareHandler> {
  StreamSubscription<List<SharedMediaFile>>? _shareSub;

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && !Platform.isWindows) {
      _handleInitialShare();
      _handleInitialBackupFile();
      _listenForShareIntents();
    }
  }

  @override
  void dispose() {
    _shareSub?.cancel();
    super.dispose();
  }

  // ── Cold-start share (app launched via share intent) ──

  Future<void> _handleInitialShare() async {
    try {
      final initial = await ReceiveSharingIntent.instance.getInitialMedia();
      if (initial.isEmpty || !mounted) return;
      for (final file in initial) {
        if (file.path.endsWith('.json')) {
          _handleBackupFile(file.path);
          return;
        }
      }
      final url = _extractUrlFromMedia(initial);
      if (url != null) _quickSave(url);
    } catch (_) {}
  }

  // ── Cold-start backup file (ACTION_VIEW .json) ──

  Future<void> _handleInitialBackupFile() async {
    try {
      const channel = MethodChannel('app.articlehub/backup');
      final path = await channel.invokeMethod<String>('getInitialBackupFile');
      if (path != null && path.isNotEmpty && mounted) {
        _handleBackupFile(path);
      }
    } catch (_) {}
  }

  // ── Warm share (app already running) ──

  void _listenForShareIntents() {
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen(
      (media) {
        if (media.isEmpty || !mounted) return;
        for (final file in media) {
          if (file.path.endsWith('.json')) {
            _handleBackupFile(file.path);
            return;
          }
        }
        final url = _extractUrlFromMedia(media);
        if (url != null) _quickSave(url);
      },
      onError: (_) {},
    );
  }

  // ── Backup import ──

  Future<void> _handleBackupFile(String path) async {
    if (!mounted) return;
    try {
      final backup = ref.read(backupServiceProvider);
      final result = await backup.importBackupFromFile(path);
      if (result != null && mounted) {
        ref.invalidate(articlesProvider);
        ref.invalidate(settingsProvider);
        final s = ref.read(stringsProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${s.imported} ${result.articles} ${s.nWithoutSummary}'),
          ),
        );
      }
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to import backup file')),
        );
      }
    }
  }

  // ── URL extraction from shared media ──

  String? _extractUrlFromMedia(List<SharedMediaFile> media) {
    for (final file in media) {
      final text = file.path.trim();
      if (text.isEmpty) continue;
      final url = _findUrlInText(text);
      if (url != null) return url;
    }
    return null;
  }

  String? _findUrlInText(String text) {
    final cleaned = cleanUrl(text);
    if (isValidUrl(cleaned)) return cleaned;
    final urlPattern = RegExp(r'https?://[^\s]+');
    final match = urlPattern.firstMatch(text);
    if (match != null) {
      final candidate = match.group(0);
      if (candidate != null) {
        final c = cleanUrl(candidate);
        if (isValidUrl(c)) return c;
      }
    }
    return null;
  }

  // ── Quick save ──

  Future<void> _quickSave(String url) async {
    final s = ref.read(stringsProvider);
    final cleaned = cleanUrl(url);
    if (!isValidUrl(cleaned)) return;

    final existing = ref.read(articlesProvider).valueOrNull;
    final duplicate = existing?.where((a) => a.url == cleaned).firstOrNull;
    if (duplicate != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${s.alreadySaved}: ${duplicate.title}')),
      );
      return;
    }

    final article = Article(
      id: const Uuid().v4(),
      url: cleaned,
      title: extractDomain(cleaned),
      source: SourcePlatform.fromUrl(cleaned),
      processingStatus: ProcessingStatus.pending,
    );

    await ref.read(articlesProvider.notifier).add(article);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(s.savedProcessing)),
    );

    // Fire-and-forget processing pipeline.
    _processArticle(article);
  }

  void _processArticle(Article article) {
    final s = ref.read(stringsProvider);
    final pipeline = ref.read(processingPipelineProvider);
    pipeline.process(article).then((result) {
      if (result != null && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              result.processingStatus == ProcessingStatus.completed
                  ? '${s.processed}: ${result.title}'
                  : '${s.failed}: ${result.processingError ?? "unknown error"}',
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }).catchError((_) => null);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
