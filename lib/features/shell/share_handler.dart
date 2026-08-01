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
import '../../shared/providers/pipeline_provider.dart';
import '../../shared/providers/auth_provider.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/utils/url_helpers.dart';
import '../../shared/utils/snackbar_helpers.dart';
import '../../data/services/attachment_store.dart';
import '../../data/services/local_file_importer.dart';
import '../../data/services/local_image_importer.dart';
import 'share_save_sheet.dart';

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
  bool _sheetOpen = false;

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
      await _handleSharedMedia(initial);
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
    _shareSub = ReceiveSharingIntent.instance.getMediaStream().listen((media) {
      if (media.isEmpty || !mounted) return;
      _handleSharedMedia(media);
    }, onError: (_) {});
  }

  Future<void> _handleSharedMedia(List<SharedMediaFile> media) async {
    for (final file in media) {
      if (file.path.endsWith('.json')) {
        _handleBackupFile(file.path);
        return;
      }
    }

    // Prefer local PDF files for import.
    for (final file in media) {
      final path = file.path;
      final mime = file.mimeType;
      final looksPdf =
          (mime != null && mime == 'application/pdf') || isPdfPath(path);
      if (!looksPdf) continue;
      // Skip if path is actually a URL string.
      if (path.startsWith('http://') || path.startsWith('https://')) continue;
      await _saveSharedPdf(path);
      return;
    }

    final sharedImages = <LocalImageCandidate>[];
    for (final file in media) {
      final path = file.path;
      if (path.startsWith('http://') || path.startsWith('https://')) continue;
      final mime = (file.mimeType ?? mimeFromPath(path))?.toLowerCase();
      if (mime == null ||
          !supportedImageUnderstandingMimeTypes.contains(mime)) {
        continue;
      }
      sharedImages.add(
        LocalImageCandidate(
          path: path,
          fileName: path.replaceAll('\\', '/').split('/').last,
          mimeType: mime,
        ),
      );
    }
    if (sharedImages.isNotEmpty) {
      await _saveSharedImages(sharedImages);
      return;
    }

    final url = _extractUrlFromMedia(media);
    if (url != null) _promptSave(url);
  }

  Future<void> _saveSharedImages(List<LocalImageCandidate> images) async {
    if (!mounted || _sheetOpen) return;
    final s = ref.read(stringsProvider);
    final selected = images.take(maxImagesPerMemory).toList();
    if (images.length > maxImagesPerMemory) {
      showAppSnackBar(context, message: s.imageSelectionLimit);
    }
    _sheetOpen = true;
    try {
      final result = await ShareSaveSheet.showImages(context, selected.length);
      if (result == null || !mounted) return;
      final prepared = await LocalImageImporter().prepare(
        images: selected,
        notes: result.notes,
        fullText: result.mode == ShareSaveMode.fullText,
        processImages: ref.read(currentSessionProvider) != null,
      );
      await ref.read(articlesProvider.notifier).add(prepared);
      if (mounted) showAppSnackBar(context, message: s.savedProcessing);
    } catch (error) {
      if (mounted) {
        showAppSnackBar(context, message: '${s.fileReadError}: $error');
      }
    } finally {
      _sheetOpen = false;
    }
  }

  Future<void> _saveSharedPdf(String path) async {
    if (!mounted) return;
    final s = ref.read(stringsProvider);
    if (_sheetOpen) return;
    _sheetOpen = true;
    try {
      showAppSnackBar(context, message: s.pdfExtracting);
      final importer = LocalFileImporter();
      final prepared = await importer.prepare(sourcePath: path);
      if (prepared.content.trim().isEmpty) {
        if (mounted) {
          showAppSnackBar(context, message: s.pdfNoTextFound);
        }
        return;
      }
      await ref.read(articlesProvider.notifier).add(prepared.article);
      if (!mounted) return;
      showAppSnackBar(context, message: s.savedProcessing);
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context, message: '${s.fileReadError}: $e');
      }
    } finally {
      _sheetOpen = false;
    }
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
        showAppSnackBar(
          context,
          message: '${s.imported} ${result.articles} ${s.nWithoutSummary}',
        );
      }
      final file = File(path);
      if (file.existsSync()) {
        await file.delete();
      }
    } catch (_) {
      if (mounted) {
        showAppSnackBar(context, message: 'Failed to import backup file');
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

  // ── Share prompt + save ──

  Future<void> _promptSave(String url) async {
    final s = ref.read(stringsProvider);
    final cleaned = cleanUrl(url);
    if (!isValidUrl(cleaned) || !mounted) return;

    final existing = ref.read(articlesProvider).valueOrNull;
    final duplicate = existing?.where((a) => a.url == cleaned).firstOrNull;
    if (duplicate != null) {
      showAppSnackBar(
        context,
        message: '${s.alreadySaved}: ${duplicate.title}',
      );
      return;
    }

    if (_sheetOpen) return;
    _sheetOpen = true;
    try {
      final result = await ShareSaveSheet.show(context, cleaned);
      if (result == null || !mounted) return;
      await _saveShared(cleaned, result);
    } finally {
      _sheetOpen = false;
    }
  }

  Future<void> _saveShared(String cleaned, ShareSaveResult result) async {
    final s = ref.read(stringsProvider);
    final fullText = result.mode == ShareSaveMode.fullText;

    final article = Article(
      id: const Uuid().v4(),
      url: cleaned,
      title: extractDomain(cleaned),
      source: SourcePlatform.fromUrl(cleaned),
      notes: result.notes,
      isFullText: fullText,
      processingStatus: ProcessingStatus.pending,
    );

    await ref.read(articlesProvider.notifier).add(article);

    if (!mounted) return;
    showAppSnackBar(context, message: s.savedProcessing);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
