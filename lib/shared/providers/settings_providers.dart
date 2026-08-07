import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../data/models/settings.dart';
import '../../data/models/source_platform.dart';
import '../../data/services/sync_outbox_service.dart';
import 'article_providers.dart';
import 'auth_provider.dart';
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
    _ref.listen(authControllerProvider, (_, next) {
      next.whenData((session) {
        if (session == null) unawaited(_forceByokMode());
      });
    });
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
    await _ref
        .read(authControllerProvider)
        .when(
          data: (session) async {
            if (session == null) await _forceByokMode();
          },
          error: (_, _) async {},
          loading: () async {},
        );
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

  Future<void> setChatAiConfig({
    String? baseUrl,
    String? apiKey,
    String? model,
  }) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(
      current.copyWith(
        chatAiBaseUrl: baseUrl,
        chatAiApiKey: apiKey,
        chatAiModel: model,
      ),
    );
  }

  Future<void> setImageAiConfig({
    String? baseUrl,
    String? apiKey,
    String? model,
  }) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(
      current.copyWith(
        imageAiBaseUrl: baseUrl,
        imageAiApiKey: apiKey,
        imageAiModel: model,
      ),
    );
  }

  /// Switches between BYOK (0) and hosted (1) AI provider modes and, for the
  /// hosted mode, records the selected model id.
  Future<void> setAiProviderMode(
    int mode, {
    String? hostedModel,
    String? hostedChatModel,
    String? hostedVisionModel,
  }) async {
    final current = state.valueOrNull ?? AppSettings();
    final canUseHosted = mode == 1 && _ref.read(currentSessionProvider) != null;
    await _save(
      current.copyWith(
        aiProviderMode: canUseHosted ? 1 : 0,
        hostedAiModel: _hostedTextModel(hostedModel ?? current.hostedAiModel),
        hostedChatModel: _hostedTextModel(
          hostedChatModel ?? current.hostedChatModel,
        ),
        hostedVisionModel: _hostedVisionModel(
          hostedVisionModel ?? current.hostedVisionModel,
        ),
      ),
    );
  }

  Future<void> setHostedAiModels({
    String? summaryModel,
    String? chatModel,
    String? visionModel,
  }) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(
      current.copyWith(
        hostedAiModel: _hostedTextModel(summaryModel ?? current.hostedAiModel),
        hostedChatModel: _hostedTextModel(chatModel ?? current.hostedChatModel),
        hostedVisionModel: _hostedVisionModel(
          visionModel ?? current.hostedVisionModel,
        ),
      ),
    );
  }

  Future<void> _forceByokMode() async {
    final current = state.valueOrNull;
    if (current == null || current.aiProviderMode == 0) return;
    await _save(current.copyWith(aiProviderMode: 0));
  }

  String _hostedTextModel(String value) {
    return AppSettings.hostedTextModels.contains(value)
        ? value
        : AppSettings.defaultHostedTextModel;
  }

  String _hostedVisionModel(String value) {
    return AppSettings.hostedVisionModels.contains(value)
        ? value
        : AppSettings.defaultHostedVisionModel;
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
        data: (s) => s.aiProviderMode == 1
            ? s.hostedAiModel.trim().isNotEmpty &&
                  ref.watch(currentSessionProvider) != null
            : s.aiBaseUrl.trim().isNotEmpty && s.aiApiKey.trim().isNotEmpty,
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
