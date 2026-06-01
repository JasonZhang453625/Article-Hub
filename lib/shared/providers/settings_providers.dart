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
