import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../data/models/settings.dart';
import '../../data/models/source_platform.dart';
import 'passage_providers.dart';

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
    final settings = _box!.get(_key) ?? AppSettings();
    state = AsyncValue.data(settings);
  }

  Future<void> _save(AppSettings settings) async {
    _box ??= await Hive.openBox<AppSettings>(_boxName);
    await _box!.put(_key, settings);
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
  /// Hive store. The key is stored locally on-device (never transmitted); it
  /// is excluded from JSON backup export via [AppSettings.toJson].
  Future<void> setAiConfig({
    String? baseUrl,
    String? apiKey,
    String? model,
  }) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(
      aiBaseUrl: baseUrl,
      aiApiKey: apiKey,
      aiModel: model,
    ));
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

  Future<void> setEmbeddingConfig({
    String? baseUrl,
    String? apiKey,
    String? model,
  }) async {
    final current = state.valueOrNull ?? AppSettings();
    await _save(current.copyWith(
      embeddingBaseUrl: baseUrl,
      embeddingApiKey: apiKey,
      embeddingModel: model,
    ));
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
}

/// Derived providers for convenience.
final themeModeProvider = Provider<ThemeMode>((ref) {
  return ref.watch(settingsProvider).maybeWhen(
    data: (s) => s.themeMode,
    orElse: () => ThemeMode.light,
  );
});

final fontSizeProvider = Provider<double>((ref) {
  return ref.watch(settingsProvider).maybeWhen(
    data: (s) => s.fontSize,
    orElse: () => 14.0,
  );
});

final webZoomProvider = Provider<int>((ref) {
  return ref.watch(settingsProvider).maybeWhen(
    data: (s) => s.webZoomPercent,
    orElse: () => 100,
  );
});

final clipboardDetectionEnabledProvider = Provider<bool>((ref) {
  return ref.watch(settingsProvider).maybeWhen(
    data: (s) => s.clipboardDetectionEnabled,
    orElse: () => false,
  );
});

/// True only when base URL, model, AND API key are all present. The key is
/// stored locally on the device (see [AppSettings.aiApiKey]) and excluded from
/// backups; it is never transmitted to any server other than the user's own
/// AI provider during a summary request.
final aiConfiguredProvider = Provider<bool>((ref) {
  return ref.watch(settingsProvider).maybeWhen(
    data: (s) =>
        s.aiBaseUrl.trim().isNotEmpty && s.aiApiKey.trim().isNotEmpty,
    orElse: () => false,
  );
});

final orderedSourcePlatformsProvider = Provider<List<SourcePlatform>>((ref) {
  return ref.watch(settingsProvider).maybeWhen(
    data: (settings) => settings.orderedSourcePlatforms,
    orElse: () => SourcePlatform.values,
  );
});

final visibleSourcePlatformsProvider = Provider<List<SourcePlatform>>((ref) {
  return ref.watch(settingsProvider).maybeWhen(
    data: (settings) => settings.visibleSourcePlatforms,
    orElse: () => SourcePlatform.values,
  );
});

final languageIndexProvider = Provider<int>((ref) {
  return ref.watch(settingsProvider).maybeWhen(
    data: (s) => s.languageIndex,
    orElse: () => 0,
  );
});

final summaryVerbosityProvider = Provider<int>((ref) {
  return ref.watch(settingsProvider).maybeWhen(
    data: (s) => s.summaryVerbosityIndex,
    orElse: () => 0,
  );
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
