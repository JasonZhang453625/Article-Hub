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

  /// When true, the app checks the clipboard on launch/resume and offers to
  /// save a detected URL.
  bool clipboardDetectionEnabled;

  /// AI configuration for auto-summarization (BYOK).
  ///
  /// The API key is stored locally on the device (never transmitted — the app
  /// calls the user's own AI provider directly). We deliberately do NOT
  /// additionally encrypt it: the threat model is "attacker has the unlocked
  /// device or root access", against which app-level encryption provides no
  /// real protection (the decryption path lives in the same app). The one
  /// protection that does matter is applied in [toJson]: the key is excluded
  /// from exported JSON backups so it can't leak via a shared file.
  /// See `docs/PRD.md` (AI key storage decision) for the full rationale.
  String aiBaseUrl;
  String aiApiKey;
  String aiModel;

  /// Language: 0 = follow system, 1 = Chinese, 2 = English
  int languageIndex;

  AppSettings({
    this.fontSize = 14.0,
    this.webZoomPercent = 100,
    this.themeModeIndex = 1,
    this.clipboardDetectionEnabled = true,
    this.aiBaseUrl = '',
    this.aiApiKey = '',
    this.aiModel = 'gpt-4o-mini',
    this.languageIndex = 0,
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
    bool? clipboardDetectionEnabled,
    String? aiBaseUrl,
    String? aiApiKey,
    String? aiModel,
    int? languageIndex,
    List<String>? sourcePlatformOrder,
    List<String>? hiddenSourcePlatforms,
  }) {
    return AppSettings(
      fontSize: fontSize ?? this.fontSize,
      webZoomPercent: webZoomPercent ?? this.webZoomPercent,
      themeModeIndex: themeModeIndex ?? this.themeModeIndex,
      clipboardDetectionEnabled:
          clipboardDetectionEnabled ?? this.clipboardDetectionEnabled,
      aiBaseUrl: aiBaseUrl ?? this.aiBaseUrl,
      aiApiKey: aiApiKey ?? this.aiApiKey,
      aiModel: aiModel ?? this.aiModel,
      languageIndex: languageIndex ?? this.languageIndex,
      sourcePlatformOrder:
          sourcePlatformOrder ?? this.sourcePlatformOrder,
      hiddenSourcePlatforms:
          hiddenSourcePlatforms ?? this.hiddenSourcePlatforms,
    );
  }

  /// Serializes to JSON for the backup/export path.
  ///
  /// The API key is deliberately omitted: a backup file is a portable,
  /// shareable artifact, so it must never carry a live secret even though the
  /// key is stored locally on the device. This is the one protection that
  /// actually matters for this threat model. Importers will prompt the user to
  /// re-enter the key.
  Map<String, dynamic> toJson() {
    return {
      'fontSize': fontSize,
      'webZoomPercent': webZoomPercent,
      'themeModeIndex': themeModeIndex,
      'clipboardDetectionEnabled': clipboardDetectionEnabled,
      'aiBaseUrl': aiBaseUrl,
      'aiModel': aiModel,
      'languageIndex': languageIndex,
      'sourcePlatformOrder': sourcePlatformOrder,
      'hiddenSourcePlatforms': hiddenSourcePlatforms,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14.0,
      webZoomPercent: (json['webZoomPercent'] as num?)?.toInt() ?? 100,
      themeModeIndex: (json['themeModeIndex'] as num?)?.toInt() ?? 1,
      clipboardDetectionEnabled:
          json['clipboardDetectionEnabled'] is bool
              ? json['clipboardDetectionEnabled'] as bool
              : true,
      aiBaseUrl: json['aiBaseUrl'] is String ? json['aiBaseUrl'] as String : '',
      // Backups never contain the key (see toJson), so this is almost always
      // empty on import — the user re-enters it. Read defensively anyway.
      aiApiKey: json['aiApiKey'] is String ? json['aiApiKey'] as String : '',
      aiModel: json['aiModel'] is String ? json['aiModel'] as String : 'gpt-4o-mini',
      languageIndex: (json['languageIndex'] as num?)?.toInt() ?? 0,
      sourcePlatformOrder:
          (json['sourcePlatformOrder'] as List?)?.whereType<String>().toList(),
      hiddenSourcePlatforms: (json['hiddenSourcePlatforms'] as List?)
          ?.whereType<String>()
          .toList(),
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
      clipboardDetectionEnabled: (fields[5] as bool?) ?? true,
      aiBaseUrl: (fields[6] as String?) ?? '',
      aiApiKey: (fields[7] as String?) ?? '',
      aiModel: (fields[8] as String?) ?? 'gpt-4o-mini',
      languageIndex: (fields[9] as int?) ?? 0,
    );
  }

  @override
  void write(BinaryWriter writer, AppSettings obj) {
    writer
      ..writeByte(10)
      ..writeByte(0)
      ..write(obj.fontSize)
      ..writeByte(1)
      ..write(obj.webZoomPercent)
      ..writeByte(2)
      ..write(obj.themeModeIndex)
      ..writeByte(3)
      ..write(obj.sourcePlatformOrder)
      ..writeByte(4)
      ..write(obj.hiddenSourcePlatforms)
      ..writeByte(5)
      ..write(obj.clipboardDetectionEnabled)
      ..writeByte(6)
      ..write(obj.aiBaseUrl)
      ..writeByte(7)
      ..write(obj.aiApiKey)
      ..writeByte(8)
      ..write(obj.aiModel)
      ..writeByte(9)
      ..write(obj.languageIndex);
  }
}
