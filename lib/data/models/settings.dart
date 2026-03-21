import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

class AppSettings {
  static const int typeId = 2;

  double fontSize;
  int webZoomPercent;

  /// 0 = system, 1 = light, 2 = dark
  int themeModeIndex;

  AppSettings({
    this.fontSize = 14.0,
    this.webZoomPercent = 100,
    this.themeModeIndex = 1,
  });

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
  }) {
    return AppSettings(
      fontSize: fontSize ?? this.fontSize,
      webZoomPercent: webZoomPercent ?? this.webZoomPercent,
      themeModeIndex: themeModeIndex ?? this.themeModeIndex,
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
    );
  }

  @override
  void write(BinaryWriter writer, AppSettings obj) {
    writer
      ..writeByte(3)
      ..writeByte(0)
      ..write(obj.fontSize)
      ..writeByte(1)
      ..write(obj.webZoomPercent)
      ..writeByte(2)
      ..write(obj.themeModeIndex);
  }
}
