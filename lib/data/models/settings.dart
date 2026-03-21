import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import 'source_platform.dart';

class AppSettings {
  static const int typeId = 2;

  double fontSize;
  int webZoomPercent;

  /// 0 = system, 1 = light, 2 = dark
  int themeModeIndex;
  List<String> sourcePlatformOrder;
  List<String> hiddenSourcePlatforms;

  AppSettings({
    this.fontSize = 14.0,
    this.webZoomPercent = 100,
    this.themeModeIndex = 1,
    List<String>? sourcePlatformOrder,
    List<String>? hiddenSourcePlatforms,
  }) : sourcePlatformOrder = normalizeSourcePlatformOrder(
          sourcePlatformOrder ?? defaultSourcePlatformOrder,
        ),
       hiddenSourcePlatforms = normalizeHiddenSourcePlatforms(
          hiddenSourcePlatforms ?? const [],
        );

  static List<String> get defaultSourcePlatformOrder =>
      SourcePlatform.values.map((platform) => platform.name).toList();

  static List<String> normalizeSourcePlatformOrder(Iterable<String> order) {
    final validNames = defaultSourcePlatformOrder;
    final normalized = <String>[];

    for (final name in order) {
      if (validNames.contains(name) && !normalized.contains(name)) {
        normalized.add(name);
      }
    }

    for (final name in validNames) {
      if (!normalized.contains(name)) {
        normalized.add(name);
      }
    }

    return normalized;
  }

  static List<String> normalizeHiddenSourcePlatforms(Iterable<String> names) {
    final validNames = defaultSourcePlatformOrder.toSet();
    final normalized = <String>[];

    for (final name in names) {
      if (validNames.contains(name) && !normalized.contains(name)) {
        normalized.add(name);
      }
    }

    return normalized;
  }

  List<SourcePlatform> get orderedSourcePlatforms {
    return sourcePlatformOrder
        .map(SourcePlatform.values.byName)
        .toList(growable: false);
  }

  Set<String> get hiddenSourcePlatformNameSet {
    return hiddenSourcePlatforms.toSet();
  }

  List<SourcePlatform> get visibleSourcePlatforms {
    final hiddenNames = hiddenSourcePlatformNameSet;
    return orderedSourcePlatforms
        .where((platform) => !hiddenNames.contains(platform.name))
        .toList(growable: false);
  }

  ThemeMode get themeMode {
    switch (themeModeIndex) {
      case 1:
        return ThemeMode.light;
      case 2:
        return ThemeMode.dark;
      default:
        return ThemeMode.system;
    }
  }

  AppSettings copyWith({
    double? fontSize,
    int? webZoomPercent,
    int? themeModeIndex,
    List<String>? sourcePlatformOrder,
    List<String>? hiddenSourcePlatforms,
  }) {
    return AppSettings(
      fontSize: fontSize ?? this.fontSize,
      webZoomPercent: webZoomPercent ?? this.webZoomPercent,
      themeModeIndex: themeModeIndex ?? this.themeModeIndex,
      sourcePlatformOrder:
          sourcePlatformOrder ?? this.sourcePlatformOrder,
      hiddenSourcePlatforms:
          hiddenSourcePlatforms ?? this.hiddenSourcePlatforms,
    );
  }
}

class AppSettingsAdapter extends TypeAdapter<AppSettings> {
  @override
  final int typeId = AppSettings.typeId;

  @override
  AppSettings read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return AppSettings(
      fontSize: (fields[0] as num?)?.toDouble() ?? 14.0,
      webZoomPercent: (fields[1] as int?) ?? 100,
      themeModeIndex: (fields[2] as int?) ?? 1,
      sourcePlatformOrder:
          (fields[3] as List?)?.cast<String>(),
      hiddenSourcePlatforms:
          (fields[4] as List?)?.cast<String>(),
    );
  }

  @override
  void write(BinaryWriter writer, AppSettings obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.fontSize)
      ..writeByte(1)
      ..write(obj.webZoomPercent)
      ..writeByte(2)
      ..write(obj.themeModeIndex)
      ..writeByte(3)
      ..write(obj.sourcePlatformOrder)
      ..writeByte(4)
      ..write(obj.hiddenSourcePlatforms);
  }
}
