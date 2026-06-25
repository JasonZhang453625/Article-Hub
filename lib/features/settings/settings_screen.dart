import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../../config/routes.dart';
import '../../data/models/passage.dart';
import '../../data/models/settings.dart';
import '../../data/services/backup_service.dart';
import '../../data/services/index_service.dart';
import '../../data/services/processing_pipeline.dart';
import '../../shared/providers/passage_providers.dart';
import '../../shared/providers/locale_provider.dart';
import '../../shared/providers/settings_providers.dart';
import '../../shared/widgets/delayed_reveal.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  late final Future<PackageInfo> _packageInfoFuture;

  // Transient slider values while dragging, so we only persist to Hive once
  // the gesture ends (onChangeEnd) instead of on every division (onChanged).
  double? _draggingFontSize;
  double? _draggingWebZoom;

  bool _isExporting = false;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _packageInfoFuture = PackageInfo.fromPlatform();
  }

  @override
  Widget build(BuildContext context) {
    final settingsAsync = ref.watch(settingsProvider);
    final s = ref.watch(stringsProvider);
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final cardColor = theme.colorScheme.surface;
    final outlineColor = theme.colorScheme.outline;

    return Scaffold(
      appBar: AppBar(
        title: Text(s.tabSettings),
      ),
      body: settingsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(child: Text('Error: $e')),
        data: (settings) {
          return DelayedReveal(
            delayMs: 40,
            beginOffset: const Offset(0, 0.035),
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                // ── Appearance Section ──
                _SectionLabel(label: s.appearance, theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.themeMode,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _ThemeModeButton(
                            icon: Icons.brightness_auto_rounded,
                            label: s.system,
                            isSelected: settings.themeModeIndex == 0,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setThemeMode(0),
                            theme: theme,
                          ),
                          const SizedBox(width: 10),
                          _ThemeModeButton(
                            icon: Icons.light_mode_rounded,
                            label: s.light,
                            isSelected: settings.themeModeIndex == 1,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setThemeMode(1),
                            theme: theme,
                          ),
                          const SizedBox(width: 10),
                          _ThemeModeButton(
                            icon: Icons.dark_mode_rounded,
                            label: s.dark,
                            isSelected: settings.themeModeIndex == 2,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setThemeMode(2),
                            theme: theme,
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      Text(
                        s.language,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _ThemeModeButton(
                            icon: Icons.language_rounded,
                            label: s.system,
                            isSelected: settings.languageIndex == 0,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setLanguage(0),
                            theme: theme,
                          ),
                          const SizedBox(width: 10),
                          _ThemeModeButton(
                            icon: Icons.translate_rounded,
                            label: '中文',
                            isSelected: settings.languageIndex == 1,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setLanguage(1),
                            theme: theme,
                          ),
                          const SizedBox(width: 10),
                          _ThemeModeButton(
                            icon: Icons.translate_rounded,
                            label: 'English',
                            isSelected: settings.languageIndex == 2,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setLanguage(2),
                            theme: theme,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // ── Font Size Section ──
                _SectionLabel(label: s.fontSizeSection, theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.text_fields_rounded,
                              size: 20,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 10),
                          Text(
                            s.textSize,
                            style: theme.textTheme.titleMedium,
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${(_draggingFontSize ?? settings.fontSize).round()}',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Row(
                        children: [
                          const Text('A',
                              style: TextStyle(
                                  fontSize: 12, fontWeight: FontWeight.w600)),
                          Expanded(
                            child: Slider(
                              value: _draggingFontSize ?? settings.fontSize,
                              min: 10,
                              max: 24,
                              divisions: 14,
                              label: (_draggingFontSize ?? settings.fontSize)
                                  .round()
                                  .toString(),
                              onChanged: (v) {
                                setState(() => _draggingFontSize = v);
                              },
                              onChangeEnd: (v) {
                                ref
                                    .read(settingsProvider.notifier)
                                    .setFontSize(v);
                                setState(() => _draggingFontSize = null);
                              },
                            ),
                          ),
                          const Text('A',
                              style: TextStyle(
                                  fontSize: 22, fontWeight: FontWeight.w600)),
                        ],
                      ),
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          s.preview,
                          style: theme.textTheme.bodyMedium,
                        ),
                      ),
                      const SizedBox(height: 12),
                      Divider(
                        height: 1,
                        color: outlineColor.withValues(alpha: 0.25),
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          Icon(Icons.zoom_in_rounded,
                              size: 20,
                              color: theme.colorScheme.primary),
                          const SizedBox(width: 10),
                          Text(
                            s.defaultWebZoom,
                            style: theme.textTheme.titleMedium,
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary
                                  .withValues(alpha: 0.1),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Text(
                              '${(_draggingWebZoom ?? settings.webZoomPercent.toDouble()).round()}%',
                              style: TextStyle(
                                color: theme.colorScheme.primary,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Slider(
                        value: _draggingWebZoom ??
                            settings.webZoomPercent.toDouble(),
                        min: 50,
                        max: 200,
                        divisions: 30,
                        label:
                            '${(_draggingWebZoom ?? settings.webZoomPercent.toDouble()).round()}%',
                        onChanged: (v) {
                          setState(() => _draggingWebZoom = v);
                        },
                        onChangeEnd: (v) {
                          ref
                              .read(settingsProvider.notifier)
                              .setWebZoom(v.round());
                          setState(() => _draggingWebZoom = null);
                        },
                      ),
                      Text(
                        s.webZoomDesc,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? Colors.white54
                              : const Color(0xFF6C8594),
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // ── Summary Style Section ──
                _SectionLabel(label: s.summaryStyle, theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        s.summaryStyle,
                        style: theme.textTheme.titleMedium,
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          _ThemeModeButton(
                            icon: Icons.short_text_rounded,
                            label: s.brief,
                            isSelected: settings.summaryVerbosityIndex == 0,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setSummaryVerbosity(0),
                            theme: theme,
                          ),
                          const SizedBox(width: 10),
                          _ThemeModeButton(
                            icon: Icons.notes_rounded,
                            label: s.detailed,
                            isSelected: settings.summaryVerbosityIndex == 1,
                            onTap: () => ref
                                .read(settingsProvider.notifier)
                                .setSummaryVerbosity(1),
                            theme: theme,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 14),

                // ── Behavior Section ──
                _SectionLabel(label: s.behavior, theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 20, vertical: 6),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border:
                        Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(s.detectClipboard),
                    subtitle: Text(
                      s.detectClipboardDesc,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? Colors.white54
                            : const Color(0xFF6C8594),
                      ),
                    ),
                    value: settings.clipboardDetectionEnabled,
                    onChanged: (value) {
                      ref
                          .read(settingsProvider.notifier)
                          .setClipboardDetectionEnabled(value);
                    },
                  ),
                ),

                const SizedBox(height: 14),

                // ── AI Section ──
                _SectionLabel(label: s.aiSummarySection, theme: theme),
                const SizedBox(height: 8),
                _AiSettingsCard(settings: settings, theme: theme, cardColor: cardColor, outlineColor: outlineColor, isDark: isDark),

                const SizedBox(height: 14),

                // ── Batch Knowledge-ification ──
                _BatchProcessCard(cardColor: cardColor, outlineColor: outlineColor, isDark: isDark, theme: theme),

                const SizedBox(height: 14),

                // ── Embedding & Index Section ──
                _SectionLabel(label: s.embeddingSection, theme: theme),
                const SizedBox(height: 8),
                _EmbeddingSettingsCard(settings: settings, theme: theme, cardColor: cardColor, outlineColor: outlineColor, isDark: isDark),
                const SizedBox(height: 12),
                _IndexManagementCard(cardColor: cardColor, outlineColor: outlineColor, isDark: isDark, theme: theme),

                const SizedBox(height: 14),

                // ── Source Platforms Section ──
                _SectionLabel(label: s.sourcePlatforms, theme: theme),
                const SizedBox(height: 8),
                _NavTile(
                  icon: Icons.dynamic_feed_rounded,
                  title: s.reorderAndHide,
                  subtitle: s.reorderDesc,
                  cardColor: cardColor,
                  outlineColor: outlineColor,
                  isDark: isDark,
                  theme: theme,
                  onTap: () =>
                      context.push(AppRoutes.sourcePlatforms),
                ),

                const SizedBox(height: 14),

                // ── Data / Backup Section ──
                _SectionLabel(label: s.data, theme: theme),
                const SizedBox(height: 8),
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: cardColor,
                    borderRadius: BorderRadius.circular(24),
                    border:
                        Border.all(color: outlineColor.withValues(alpha: 0.3)),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.backupRestore, style: theme.textTheme.titleMedium),
                      const SizedBox(height: 4),
                      Text(
                        s.backupDesc,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: isDark
                              ? Colors.white54
                              : const Color(0xFF6C8594),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _isExporting ? null : _handleExport,
                              icon: _isExporting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.ios_share_rounded,
                                      size: 18),
                              label: Text(s.export),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _isImporting ? null : _handleImport,
                              icon: _isImporting
                                  ? const SizedBox(
                                      width: 18,
                                      height: 18,
                                      child: CircularProgressIndicator(
                                          strokeWidth: 2),
                                    )
                                  : const Icon(Icons.file_download_rounded,
                                      size: 18),
                              label: Text(s.import),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // ── About Section ──
                FutureBuilder<PackageInfo>(
                  future: _packageInfoFuture,
                  builder: (context, snapshot) {
                    final packageInfo = snapshot.data;
                    final versionText = packageInfo == null
                        ? 'Article-Hub'
                        : _buildVersionLabel(packageInfo);

                    return Center(
                      child: Text(
                        versionText,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color:
                              isDark ? Colors.white38 : const Color(0xFF98ADB8),
                        ),
                      ),
                    );
                  },
                ),
                const SizedBox(height: 16),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  String _buildVersionLabel(PackageInfo packageInfo) {
    final buildNumber = packageInfo.buildNumber.trim();
    final versionSuffix = buildNumber.isEmpty
        ? packageInfo.version
        : '${packageInfo.version}+$buildNumber';
    return 'Article-Hub v$versionSuffix';
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message)),
    );
  }

  Future<void> _handleExport() async {
    if (_isExporting) return;
    setState(() => _isExporting = true);
    try {
      await ref.read(backupServiceProvider).exportBackup();
    } catch (e) {
      _showSnack('${ref.read(stringsProvider).exportFailed}: $e');
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _handleImport() async {
    if (_isImporting) return;

    final s = ref.read(stringsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.importBackup),
        content: Text(s.importConfirm),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(s.import),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    setState(() => _isImporting = true);
    try {
      final result = await ref.read(backupServiceProvider).importBackup();
      if (result == null) return; // cancelled at file picker
      _showSnack(
        '${s.imported} ${result.articles} articles, '
        '${result.filterGroups} filters'
        '${result.folders > 0 ? ', ${result.folders} folders' : ''}'
        '${result.settingsImported ? ', settings' : ''}.',
      );
    } on FormatException catch (e) {
      _showSnack('${s.invalidBackup}: ${e.message}');
    } catch (e) {
      _showSnack('${s.importFailed}: $e');
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }
}

class _EmbeddingSettingsCard extends ConsumerStatefulWidget {
  final AppSettings settings;
  final ThemeData theme;
  final Color cardColor;
  final Color outlineColor;
  final bool isDark;

  const _EmbeddingSettingsCard({
    required this.settings,
    required this.theme,
    required this.cardColor,
    required this.outlineColor,
    required this.isDark,
  });

  @override
  ConsumerState<_EmbeddingSettingsCard> createState() => _EmbeddingSettingsCardState();
}

class _EmbeddingSettingsCardState extends ConsumerState<_EmbeddingSettingsCard> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;
  bool _testing = false;
  String? _testResult;

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController(text: widget.settings.embeddingBaseUrl);
    _apiKeyController = TextEditingController(text: widget.settings.embeddingApiKey);
    _modelController = TextEditingController(text: widget.settings.embeddingModel);
  }

  @override
  void didUpdateWidget(_EmbeddingSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.settings.embeddingBaseUrl != _baseUrlController.text) {
      _baseUrlController.text = widget.settings.embeddingBaseUrl;
    }
    if (widget.settings.embeddingApiKey != _apiKeyController.text) {
      _apiKeyController.text = widget.settings.embeddingApiKey;
    }
    if (widget.settings.embeddingModel != _modelController.text) {
      _modelController.text = widget.settings.embeddingModel;
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    await ref.read(settingsProvider.notifier).setEmbeddingConfig(
      baseUrl: _baseUrlController.text,
      apiKey: _apiKeyController.text,
      model: _modelController.text,
    );
  }

  Future<void> _resetToDefaults() async {
    setState(() {
      _baseUrlController.text = '';
      _apiKeyController.text = '';
      _modelController.text = '';
      _testResult = null;
    });
    await ref.read(settingsProvider.notifier).setEmbeddingConfig(
      baseUrl: '',
      apiKey: '',
      model: '',
    );
  }

  Future<void> _testConnection() async {
    final s = ref.read(stringsProvider);
    setState(() {
      _testing = true;
      _testResult = null;
    });
    await _save();
    final service = ref.read(embeddingServiceProvider);
    if (service == null) {
      setState(() {
        _testing = false;
        _testResult = s.fillAllFields;
      });
      return;
    }
    final ok = await service.testConnection();
    setState(() {
      _testing = false;
      _testResult = ok ? s.connectionSuccessful : s.connectionFailed;
    });
  }

  @override
  Widget build(BuildContext context) {
    final isUsingDefaults = !widget.settings.hasCustomEmbeddingConfig;
    final s = ref.watch(stringsProvider);

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: widget.outlineColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(s.embeddingConfig, style: widget.theme.textTheme.titleMedium),
              ),
              if (isUsingDefaults)
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: widget.theme.colorScheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    s.defaultLabel,
                    style: widget.theme.textTheme.bodySmall?.copyWith(
                      color: widget.theme.colorScheme.primary,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            isUsingDefaults
                ? s.usingBuiltIn
                : s.usingCustom,
            style: widget.theme.textTheme.bodySmall?.copyWith(
              color: widget.isDark ? Colors.white54 : const Color(0xFF6C8594),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _baseUrlController,
            decoration: InputDecoration(
              labelText: s.embeddingBaseUrl,
              hintText: AppSettings.defaultEmbeddingBaseUrl,
              prefixIcon: const Icon(Icons.link_rounded),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKeyController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: s.embeddingApiKey,
              prefixIcon: Icon(Icons.key_rounded),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelController,
            decoration: InputDecoration(
              labelText: s.embeddingModel,
              hintText: AppSettings.defaultEmbeddingModel,
              prefixIcon: const Icon(Icons.smart_toy_rounded),
            ),
            onSubmitted: (_) => _save(),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _testing ? null : _testConnection,
                  icon: _testing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.wifi_tethering_rounded),
                  label: Text(_testing ? s.testing : s.testConnection),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: _save,
                  child: Text(s.save),
                ),
              ),
            ],
          ),
          if (!isUsingDefaults) ...[
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                onPressed: _resetToDefaults,
                icon: const Icon(Icons.restart_alt_rounded, size: 18),
                label: Text(s.resetToDefaults),
              ),
            ),
          ],
          if (_testResult != null) ...[
            const SizedBox(height: 8),
            Text(
              _testResult!,
              style: widget.theme.textTheme.bodySmall?.copyWith(
                color: _testResult!.contains('successful')
                    ? Colors.green
                    : widget.theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _IndexManagementCard extends ConsumerStatefulWidget {
  final Color cardColor;
  final Color outlineColor;
  final bool isDark;
  final ThemeData theme;

  const _IndexManagementCard({
    required this.cardColor,
    required this.outlineColor,
    required this.isDark,
    required this.theme,
  });

  @override
  ConsumerState<_IndexManagementCard> createState() => _IndexManagementCardState();
}

class _IndexManagementCardState extends ConsumerState<_IndexManagementCard> {
  bool _rebuilding = false;
  String? _rebuildResult;

  Future<void> _rebuild() async {
    setState(() {
      _rebuilding = true;
      _rebuildResult = null;
    });

    final embedding = ref.read(embeddingServiceProvider);
    if (embedding == null) {
      setState(() {
        _rebuilding = false;
        _rebuildResult = ref.read(stringsProvider).configureEmbeddingFirst;
      });
      return;
    }

    final index = ref.read(indexServiceProvider);
    final articles = ref.read(articlesProvider).valueOrNull ?? [];
    final count = await rebuildIndex(
      articles: articles,
      embedding: embedding,
      index: index,
    );

    setState(() {
      _rebuilding = false;
      _rebuildResult = '${ref.read(stringsProvider).indexedN} $count articles';
    });
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    final countAsync = ref.watch(indexCountProvider);
    final indexedCount = countAsync.valueOrNull;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: widget.outlineColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.indexManagement, style: widget.theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            indexedCount != null
                ? '$indexedCount ${s.nArticlesIndexed}'
                : s.loadingIndexStatus,
            style: widget.theme.textTheme.bodySmall?.copyWith(
              color: widget.isDark ? Colors.white54 : const Color(0xFF6C8594),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _rebuilding ? null : _rebuild,
              icon: _rebuilding
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.build_rounded),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(_rebuilding ? s.rebuilding : s.rebuildIndex),
              ),
            ),
          ),
          if (_rebuildResult != null) ...[
            const SizedBox(height: 8),
            Text(
              _rebuildResult!,
              style: widget.theme.textTheme.bodySmall?.copyWith(
                color: Colors.green,
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _BatchProcessCard extends ConsumerWidget {
  final Color cardColor;
  final Color outlineColor;
  final bool isDark;
  final ThemeData theme;

  const _BatchProcessCard({
    required this.cardColor,
    required this.outlineColor,
    required this.isDark,
    required this.theme,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final articlesAsync = ref.watch(articlesProvider);
    final aiConfigured = ref.watch(aiConfiguredProvider);
    final s = ref.watch(stringsProvider);

    final articles = articlesAsync.valueOrNull ?? [];
    final needsProcessing = articles
        .where((a) =>
            a.processingStatus == ProcessingStatus.completed && a.summary == null)
        .toList();
    final unprocessedCount = needsProcessing.length;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: outlineColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.batchProcessing, style: theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            unprocessedCount == 0
                ? s.allProcessed
                : '$unprocessedCount ${s.nWithoutSummary}',
            style: theme.textTheme.bodySmall?.copyWith(
              color: isDark ? Colors.white54 : const Color(0xFF6C8594),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: unprocessedCount == 0 || !aiConfigured
                  ? null
                  : () => _startBatchProcess(context, ref, needsProcessing),
              icon: const Icon(Icons.auto_fix_high_rounded),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  !aiConfigured
                      ? s.configureAiFirstBtn
                      : unprocessedCount == 0
                          ? s.nothingToProcess
                          : s.processNArticles.replaceFirst('article(s)', unprocessedCount.toString()),
                ),
              ),
            ),
          ),
          if (!aiConfigured) ...[
            const SizedBox(height: 8),
            Text(
              s.setupAiProvider,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _startBatchProcess(
    BuildContext context,
    WidgetRef ref,
    List<Article> articles,
  ) async {
    final s = ref.read(stringsProvider);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.batchProcessing),
        content: Text(
          s.batchProcessConfirm.replaceFirst('article(s)', articles.length.toString()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(s.start),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final pipeline = ref.read(processingPipelineProvider);
    var processed = 0;
    for (final article in articles) {
      final result = await pipeline.process(article.copyWith(
        processingStatus: ProcessingStatus.pending,
      ));
      if (result != null) processed++;
    }

    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${s.processedN} $processed/${articles.length} articles')),
      );
    }
  }
}

class _SectionLabel extends StatelessWidget {
  final String label;
  final ThemeData theme;

  const _SectionLabel({required this.label, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        label,
        style: theme.textTheme.bodySmall?.copyWith(
          fontWeight: FontWeight.w700,
          letterSpacing: 0.8,
          color: theme.colorScheme.primary,
        ),
      ),
    );
  }
}

class _ThemeModeButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool isSelected;
  final VoidCallback onTap;
  final ThemeData theme;

  const _ThemeModeButton({
    required this.icon,
    required this.label,
    required this.isSelected,
    required this.onTap,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final primaryColor = theme.colorScheme.primary;
    final isDark = theme.brightness == Brightness.dark;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(vertical: 11),
            decoration: BoxDecoration(
              color: isSelected
                  ? primaryColor.withValues(alpha: 0.12)
                  : Colors.transparent,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: isSelected
                    ? primaryColor
                    : (isDark
                        ? Colors.white12
                        : const Color(0xFFD7E3EA)),
                width: isSelected ? 1.6 : 1.0,
              ),
            ),
            child: Column(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: isSelected
                      ? primaryColor
                      : theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 6),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        isSelected ? FontWeight.w700 : FontWeight.w500,
                    color: isSelected
                        ? primaryColor
                        : theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color cardColor;
  final Color outlineColor;
  final bool isDark;
  final ThemeData theme;
  final VoidCallback onTap;

  const _NavTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.cardColor,
    required this.outlineColor,
    required this.isDark,
    required this.theme,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: cardColor,
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            border:
                Border.all(color: outlineColor.withValues(alpha: 0.3)),
          ),
          child: Row(
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: theme.colorScheme.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon,
                    size: 20, color: theme.colorScheme.primary),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: theme.textTheme.titleMedium),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: isDark
                            ? Colors.white54
                            : const Color(0xFF6C8594),
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: isDark ? Colors.white38 : const Color(0xFF8AA1AF),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AiSettingsCard extends ConsumerStatefulWidget {
  final AppSettings settings;
  final ThemeData theme;
  final Color cardColor;
  final Color outlineColor;
  final bool isDark;

  const _AiSettingsCard({
    required this.settings,
    required this.theme,
    required this.cardColor,
    required this.outlineColor,
    required this.isDark,
  });

  @override
  ConsumerState<_AiSettingsCard> createState() => _AiSettingsCardState();
}

class _AiSettingsCardState extends ConsumerState<_AiSettingsCard> {
  late final TextEditingController _baseUrlController;
  late final TextEditingController _apiKeyController;
  late final TextEditingController _modelController;

  @override
  void initState() {
    super.initState();
    _baseUrlController = TextEditingController(text: widget.settings.aiBaseUrl);
    _apiKeyController = TextEditingController(text: widget.settings.aiApiKey);
    _modelController = TextEditingController(text: widget.settings.aiModel);
  }

  @override
  void didUpdateWidget(_AiSettingsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reseed controllers when the underlying settings change (e.g. after a
    // backup import replaces settings), so the fields don't show stale values.
    final s = widget.settings;
    if (s.aiBaseUrl != oldWidget.settings.aiBaseUrl) {
      _baseUrlController.text = s.aiBaseUrl;
    }
    if (s.aiApiKey != oldWidget.settings.aiApiKey) {
      _apiKeyController.text = s.aiApiKey;
    }
    if (s.aiModel != oldWidget.settings.aiModel) {
      _modelController.text = s.aiModel;
    }
  }

  @override
  void dispose() {
    _baseUrlController.dispose();
    _apiKeyController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  void _save() {
    // Key + config all go to local Hive. The key is never included in JSON
    // backup export (see AppSettings.toJson), and is never sent anywhere
    // except the user's own AI provider during a summary request.
    ref.read(settingsProvider.notifier).setAiConfig(
      baseUrl: _baseUrlController.text.trim(),
      apiKey: _apiKeyController.text.trim(),
      model: _modelController.text.trim(),
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(ref.read(stringsProvider).aiSettingsSaved)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = ref.watch(stringsProvider);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: widget.cardColor,
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: widget.outlineColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(s.apiConfig, style: widget.theme.textTheme.titleMedium),
          const SizedBox(height: 4),
          Text(
            s.apiConfigDesc,
            style: widget.theme.textTheme.bodySmall?.copyWith(
              color: widget.isDark ? Colors.white54 : const Color(0xFF6C8594),
            ),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _baseUrlController,
            decoration: InputDecoration(
              labelText: s.baseUrl,
              hintText: 'https://api.openai.com/v1',
              prefixIcon: const Icon(Icons.link_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _apiKeyController,
            obscureText: true,
            decoration: InputDecoration(
              labelText: s.apiKey,
              hintText: 'sk-...',
              prefixIcon: const Icon(Icons.key_rounded),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _modelController,
            decoration: InputDecoration(
              labelText: s.model,
              hintText: 'gpt-4o-mini',
              prefixIcon: const Icon(Icons.smart_toy_rounded),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _save,
              icon: const Icon(Icons.save_rounded),
              label: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(s.saveAiSettings),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
