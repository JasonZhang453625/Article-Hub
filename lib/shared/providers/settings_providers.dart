import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../data/models/settings.dart';
import '../../data/models/source_platform.dart';
import '../../data/services/sync_outbox_service.dart';
import 'article_providers.dart';
import 'sync_providers.dart';

final settingsProvider =
    StateNotifierProvider<SettingsNotifier, AsyncValue<AppSettings>>((ref) {
      return SettingsNotifier(ref);
    });

class SettingsNotifier extends StateNotifier<AsyncValue<AppSettings>> {
  static const String _boxName = 'app_settings';
  static const String _key = 'settings';

  final Ref _ref;
  Box<AppSettings>? _box;

  SettingsNotifier(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    await _ref.read(hiveInitProvider.future);
    _box ??= await Hive.openBox<AppSettings>(_boxName);
    var settings = _box!.get(_key) ?? AppSettings();
    // Set first launch timestamp if not already set.
    if (settings.firstLaunchMs == null) {
      settings = settings.copyWith(
        firstLaunchMs: DateTime.now().millisecondsSinceEpoch,
      );
      await _box!.put(_key, settings);
    }
    state = AsyncValue.data(settings);
  }

  Future<void> _save(AppSettings settings) async {
    _box ??= await Hive.openBox<AppSettings>(_boxName);
    await _box!.put(_key, settings);
    await _ref
        .read(syncOutboxProvider)
        .enqueue(
          SyncOutboxRecord.create(
            collection: SyncCollections.appSettings,
            itemId: _key,
            operation: SyncOperation.upsert,
            payload: settings.toSyncJson(),
          ),
        );
    state = AsyncValue.data(settings);
  }

  Future<void> setFontSize(double size) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(fontSize: size));
  }

  Future<void> setWebZoom(int percent) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(webZoomPercent: percent));
  }

  Future<void> setThemeMode(int index) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(themeModeIndex: index));
  }

  /// Replaces all settings at once (used when importing a backup).
  Future<void> replaceWith(AppSettings settings) async {
    await _save(settings);
  }

  Future<void> setClipboardDetectionEnabled(bool enabled) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(clipboardDetectionEnabled: enabled));
  }

  /// Persists the AI configuration (base URL, API key, model) to the local
  /// Hive store. Account sync sends the key as JSON over HTTPS; generic JSON
  /// serialization still omits it.
  Future<void> setAiConfig({
    String? baseUrl,
    String? apiKey,
    String? model,
  }) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(
      current.copyWith(aiBaseUrl: baseUrl, aiApiKey: apiKey, aiModel: model),
    );
  }

  Future<void> setLanguage(int index) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(languageIndex: index));
  }

  Future<void> setSummaryVerbosity(int index) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(summaryVerbosityIndex: index));
  }

  Future<void> setChatAnswerLength(int index) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(chatAnswerLengthIndex: index));
  }

  Future<void> setChatKnowledgeSource(int index) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(chatKnowledgeSourceIndex: index));
  }

  /// Persists the chat preferences together so one setting cannot overwrite
  /// the other when the settings sheet applies both values at once.
  Future<void> setChatPreferences({
    required int answerLength,
    required int knowledgeSource,
  }) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(
      current.copyWith(
        chatAnswerLengthIndex: answerLength,
        chatKnowledgeSourceIndex: knowledgeSource,
      ),
    );
  }

  Future<void> setHideInboxTab(bool hidden) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(hideInboxTab: hidden));
  }

  Future<void> setFontWeightIndex(int index) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(fontWeightIndex: index));
  }

  Future<void> setStartupTabIndex(int index) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(startupTabIndex: index));
  }

  Future<void> setMemorySortNewestFirst(bool newestFirst) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(memorySortNewestFirst: newestFirst));
  }

  Future<void> setEmbeddingConfig({
    String? baseUrl,
    String? apiKey,
    String? model,
  }) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(
      current.copyWith(
        embeddingBaseUrl: baseUrl,
        embeddingApiKey: apiKey,
        embeddingModel: model,
      ),
    );
  }

  Future<void> setTavilyApiKey(String apiKey) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(tavilyApiKey: apiKey));
  }

  Future<void> updateSourcePlatformOrder(List<String> order) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(sourcePlatformOrder: order));
  }

  Future<void> moveSourcePlatformBefore(
    String draggedName,
    String targetName,
  ) async {
    if (draggedName == targetName) return;

    final current = state.valueOrNull ?? AppSettings();
    final order = List<String>.from(current.sourcePlatformOrder)
      ..remove(draggedName);
    final targetIndex = order.indexOf(targetName);
    if (targetIndex == -1) return;

    order.insert(targetIndex, draggedName);
    await _save(current.copyWith(sourcePlatformOrder: order));
  }

  Future<void> moveSourcePlatformToEnd(String platformName) async {
    final current = state.valueOrNull ?? AppSettings();
    final order = List<String>.from(current.sourcePlatformOrder)
      ..remove(platformName)
      ..add(platformName);
    await _save(current.copyWith(sourcePlatformOrder: order));
  }

  Future<void> setSourcePlatformVisibility(
    String platformName,
    bool isVisible,
  ) async {
    final current = state.valueOrNull ?? AppSettings();
    final hidden = List<String>.from(current.hiddenSourcePlatforms);

    if (isVisible) {
      hidden.remove(platformName);
    } else if (!hidden.contains(platformName)) {
      hidden.add(platformName);
    }

    await _save(current.copyWith(hiddenSourcePlatforms: hidden));

    if (!isVisible &&
        _ref.read(selectedSourceProvider.notifier).state == platformName) {
      _ref.read(selectedSourceProvider.notifier).state = '';
    }
  }

  Future<void> addTokenUsage(int tokens) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(
      current.copyWith(totalTokensUsed: current.totalTokensUsed + tokens),
    );
  }
}

/// Derived providers for convenience.
final themeModeProvider = Provider<ThemeMode>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.themeMode, orElse: () => ThemeMode.light);
});

final fontSizeProvider = Provider<double>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.fontSize, orElse: () => 14.0);
});

final webZoomProvider = Provider<int>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.webZoomPercent, orElse: () => 100);
});

final clipboardDetectionEnabledProvider = Provider<bool>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.clipboardDetectionEnabled, orElse: () => false);
});

/// True only when base URL, model, AND API key are all present. The key is
/// stored locally on the device (see [AppSettings.aiApiKey]). Account sync can
/// copy it as JSON over HTTPS; AI requests send it to the provider selected by
/// the user.
final aiConfiguredProvider = Provider<bool>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(
        data: (s) =>
            s.aiBaseUrl.trim().isNotEmpty && s.aiApiKey.trim().isNotEmpty,
        orElse: () => false,
      );
});

final orderedSourcePlatformsProvider = Provider<List<SourcePlatform>>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(
        data: (settings) => settings.orderedSourcePlatforms,
        orElse: () => SourcePlatform.values,
      );
});

final visibleSourcePlatformsProvider = Provider<List<SourcePlatform>>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(
        data: (settings) => settings.visibleSourcePlatforms,
        orElse: () => SourcePlatform.values,
      );
});

final languageIndexProvider = Provider<int>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.languageIndex, orElse: () => 0);
});

final summaryVerbosityProvider = Provider<int>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.summaryVerbosityIndex, orElse: () => 0);
});

/// Returns the AI prompt language instruction based on the language setting.
/// 0 = follow system, 1 = Chinese, 2 = English
String aiLanguagePrompt(int languageIndex) {
  switch (languageIndex) {
    case 1:
      return 'You MUST respond in Chinese (简体中文).';
    case 2:
      return 'You MUST respond in English.';
    default:
      return 'Respond in the same language as the article title. If the title is in Chinese, respond in Chinese. If in English, respond in English.';
  }
}

final hideInboxTabProvider = Provider<bool>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.hideInboxTab, orElse: () => false);
});

final fontWeightIndexProvider = Provider<int>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.fontWeightIndex, orElse: () => 0);
});

final startupTabIndexProvider = Provider<int>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.startupTabIndex, orElse: () => 0);
});

final memorySortNewestFirstProvider = Provider<bool>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.memorySortNewestFirst, orElse: () => true);
});

/// Computed days since first launch.
final usageDaysProvider = Provider<int>((ref) {
  final ms = ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.firstLaunchMs, orElse: () => null);
  if (ms == null) return 0;
  final first = DateTime.fromMillisecondsSinceEpoch(ms);
  return DateTime.now().difference(first).inDays;
});

/// Total articles count (from the articles provider).
final articlesCountProvider = Provider<int>((ref) {
  return ref
      .watch(articlesProvider)
      .maybeWhen(data: (articles) => articles.length, orElse: () => 0);
});

/// Cumulative token usage.
final totalTokensUsedProvider = Provider<int>((ref) {
  return ref
      .watch(settingsProvider)
      .maybeWhen(data: (s) => s.totalTokensUsed, orElse: () => 0);
});
