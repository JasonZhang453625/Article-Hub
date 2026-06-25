import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../utils/locale_strings.dart';
import 'settings_providers.dart';

final localeProvider = Provider<Locale?>((ref) {
  final index = ref.watch(languageIndexProvider);
  switch (index) {
    case 1:
      return const Locale('zh');
    case 2:
      return const Locale('en');
    default:
      return null; // follow system
  }
});

final stringsProvider = Provider<LocaleStrings>((ref) {
  final index = ref.watch(languageIndexProvider);
  return LocaleStrings.of(index);
});
