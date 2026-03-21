import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import '../../data/models/settings.dart';
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
