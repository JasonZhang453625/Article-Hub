import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import 'source_platform.dart';

class AppSettings {
  static const int typeId = 2;

  /// Built-in default embedding configuration (SiliconFlow BGE-M3).
  /// Used when the user hasn't provided their own config (BYOK).
  static const String defaultEmbeddingBaseUrl = 'https://api.siliconflow.cn/v1';
  static const String defaultEmbeddingApiKey =
      'sk-goxkdsfshuekimktyiwdkexdnkdantwuhfylssothjhetcjh';
  static const String defaultEmbeddingModel = 'BAAI/bge-m3';

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
  /// The API key is stored locally on the device (never transmitted â€” the app
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

  /// Embedding configuration for semantic search / RAG (BYOK).
  ///
  /// Follows the same threat model as [aiApiKey]: the key is stored locally,
  /// never transmitted (the app calls the user's own provider), and excluded
  /// from [toJson] exports so it can't leak via a shared backup file.
  String embeddingBaseUrl;
  String embeddingApiKey;
  String embeddingModel;

  /// Language: 0 = follow system, 1 = Chinese, 2 = English
  int languageIndex;

  /// Summary verbosity: 0 = concise (3 bullets), 1 = detailed (adaptive by article length)
  int summaryVerbosityIndex;

  /// Chat answer length: 0 = short, 1 = detailed
  int chatAnswerLengthIndex;

  /// Chat knowledge source: 0 = knowledge base only, 1 = knowledge base + general knowledge
  int chatKnowledgeSourceIndex;

  /// When true, the Inbox/Progress tab is hidden in the bottom navigation bar.
  bool hideInboxTab;

  /// Font weight: 0 = normal (w400), 1 = medium (w500), 2 = semibold (w600), 3 = bold (w700)
  int fontWeightIndex;

  /// Startup tab: 0 = Chat, 1 = Knowledge
  int startupTabIndex;

  /// Memory list order: true = newest created first, false = oldest first.
  bool memorySortNewestFirst;

  /// First time the app was launched (milliseconds since epoch). Null until set.
  int? firstLaunchMs;

  /// Cumulative tokens consumed across all AI API calls.
  int totalTokensUsed;

  AppSettings({
    this.fontSize = 14.0,
    this.webZoomPercent = 100,
    this.themeModeIndex = 1,
    this.clipboardDetectionEnabled = true,
    this.aiBaseUrl = '',
    this.aiApiKey = '',
    this.aiModel = 'gpt-4o-mini',
    this.embeddingBaseUrl = '',
    this.embeddingApiKey = '',
    this.embeddingModel = '',
    this.languageIndex = 0,
    this.summaryVerbosityIndex = 0,
    this.chatAnswerLengthIndex = 0,
    this.chatKnowledgeSourceIndex = 0,
    this.hideInboxTab = false,
    this.fontWeightIndex = 0,
    this.startupTabIndex = 0,
    this.memorySortNewestFirst = true,
    this.firstLaunchMs,
    this.totalTokensUsed = 0,
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
        .map((name) {
          try {
            return SourcePlatform.values.byName(name);
          } catch (_) {
            return null;
          }
        })
        .whereType<SourcePlatform>()
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

  /// Returns true when the user has provided custom embedding config (BYOK).
  bool get hasCustomEmbeddingConfig =>
      embeddingBaseUrl.trim().isNotEmpty &&
      embeddingApiKey.trim().isNotEmpty &&
      embeddingModel.trim().isNotEmpty;

  /// Returns the effective embedding base URL (user-provided or built-in default).
  String get effectiveEmbeddingBaseUrl => embeddingBaseUrl.trim().isNotEmpty
      ? embeddingBaseUrl
      : defaultEmbeddingBaseUrl;

  /// Returns the effective embedding API key (user-provided or built-in default).
  String get effectiveEmbeddingApiKey => embeddingApiKey.trim().isNotEmpty
      ? embeddingApiKey
      : defaultEmbeddingApiKey;

  /// Returns the effective embedding model (user-provided or built-in default).
  String get effectiveEmbeddingModel =>
      embeddingModel.trim().isNotEmpty ? embeddingModel : defaultEmbeddingModel;

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

  FontWeight get fontWeight {
    switch (fontWeightIndex) {
      case 1:
        return FontWeight.w500;
      case 2:
        return FontWeight.w600;
      case 3:
        return FontWeight.w700;
      default:
        return FontWeight.w400;
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
    String? embeddingBaseUrl,
    String? embeddingApiKey,
    String? embeddingModel,
    int? languageIndex,
    int? summaryVerbosityIndex,
    int? chatAnswerLengthIndex,
    int? chatKnowledgeSourceIndex,
    bool? hideInboxTab,
    int? fontWeightIndex,
    int? startupTabIndex,
    bool? memorySortNewestFirst,
    int? firstLaunchMs,
    int? totalTokensUsed,
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
      embeddingBaseUrl: embeddingBaseUrl ?? this.embeddingBaseUrl,
      embeddingApiKey: embeddingApiKey ?? this.embeddingApiKey,
      embeddingModel: embeddingModel ?? this.embeddingModel,
      languageIndex: languageIndex ?? this.languageIndex,
      summaryVerbosityIndex:
          summaryVerbosityIndex ?? this.summaryVerbosityIndex,
      chatAnswerLengthIndex:
          chatAnswerLengthIndex ?? this.chatAnswerLengthIndex,
      chatKnowledgeSourceIndex:
          chatKnowledgeSourceIndex ?? this.chatKnowledgeSourceIndex,
      hideInboxTab: hideInboxTab ?? this.hideInboxTab,
      fontWeightIndex: fontWeightIndex ?? this.fontWeightIndex,
      startupTabIndex: startupTabIndex ?? this.startupTabIndex,
      memorySortNewestFirst:
          memorySortNewestFirst ?? this.memorySortNewestFirst,
      firstLaunchMs: firstLaunchMs ?? this.firstLaunchMs,
      totalTokensUsed: totalTokensUsed ?? this.totalTokensUsed,
      sourcePlatformOrder: sourcePlatformOrder ?? this.sourcePlatformOrder,
      hiddenSourcePlatforms:
          hiddenSourcePlatforms ?? this.hiddenSourcePlatforms,
    );
  }

  /// Serializes to JSON for backup/export and encrypted sync payloads.
  ///
  /// Provider API keys intentionally stay local to this device and are not
  /// included here.
  Map<String, dynamic> toJson() {
    return {
      'fontSize': fontSize,
      'webZoomPercent': webZoomPercent,
      'themeModeIndex': themeModeIndex,
      'clipboardDetectionEnabled': clipboardDetectionEnabled,
      'aiBaseUrl': aiBaseUrl,
      'aiModel': aiModel,
      'embeddingBaseUrl': embeddingBaseUrl,
      'embeddingModel': embeddingModel,
      'languageIndex': languageIndex,
      'summaryVerbosityIndex': summaryVerbosityIndex,
      'chatAnswerLengthIndex': chatAnswerLengthIndex,
      'chatKnowledgeSourceIndex': chatKnowledgeSourceIndex,
      'hideInboxTab': hideInboxTab,
      'fontWeightIndex': fontWeightIndex,
      'startupTabIndex': startupTabIndex,
      'memorySortNewestFirst': memorySortNewestFirst,
      'firstLaunchMs': firstLaunchMs,
      'totalTokensUsed': totalTokensUsed,
      'sourcePlatformOrder': sourcePlatformOrder,
      'hiddenSourcePlatforms': hiddenSourcePlatforms,
    };
  }

  factory AppSettings.fromJson(Map<String, dynamic> json) {
    return AppSettings(
      fontSize: (json['fontSize'] as num?)?.toDouble() ?? 14.0,
      webZoomPercent: (json['webZoomPercent'] as num?)?.toInt() ?? 100,
      themeModeIndex: (json['themeModeIndex'] as num?)?.toInt() ?? 1,
      clipboardDetectionEnabled: json['clipboardDetectionEnabled'] is bool
          ? json['clipboardDetectionEnabled'] as bool
          : true,
      aiBaseUrl: json['aiBaseUrl'] is String ? json['aiBaseUrl'] as String : '',
      aiApiKey: json['aiApiKey'] is String ? json['aiApiKey'] as String : '',
      aiModel: json['aiModel'] is String
          ? json['aiModel'] as String
          : 'gpt-4o-mini',
      embeddingBaseUrl: json['embeddingBaseUrl'] is String
          ? json['embeddingBaseUrl'] as String
          : '',
      embeddingApiKey: json['embeddingApiKey'] is String
          ? json['embeddingApiKey'] as String
          : '',
      embeddingModel: json['embeddingModel'] is String
          ? json['embeddingModel'] as String
          : '',
      languageIndex: (json['languageIndex'] as num?)?.toInt() ?? 0,
      summaryVerbosityIndex:
          (json['summaryVerbosityIndex'] as num?)?.toInt() ?? 0,
      chatAnswerLengthIndex:
          (json['chatAnswerLengthIndex'] as num?)?.toInt() ?? 0,
      chatKnowledgeSourceIndex:
          (json['chatKnowledgeSourceIndex'] as num?)?.toInt() ?? 0,
      hideInboxTab: json['hideInboxTab'] is bool
          ? json['hideInboxTab'] as bool
          : false,
      fontWeightIndex: (json['fontWeightIndex'] as num?)?.toInt() ?? 0,
      startupTabIndex: (json['startupTabIndex'] as num?)?.toInt() ?? 0,
      memorySortNewestFirst: json['memorySortNewestFirst'] is bool
          ? json['memorySortNewestFirst'] as bool
          : true,
      firstLaunchMs: json['firstLaunchMs'] as int?,
      totalTokensUsed: (json['totalTokensUsed'] as num?)?.toInt() ?? 0,
      sourcePlatformOrder: (json['sourcePlatformOrder'] as List?)
          ?.whereType<String>()
          .toList(),
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
      webZoomPercent: (fields[1] as num?)?.toInt() ?? 100,
      themeModeIndex: (fields[2] as num?)?.toInt() ?? 1,
      sourcePlatformOrder: (fields[3] as List?)?.cast<String>(),
      hiddenSourcePlatforms: (fields[4] as List?)?.cast<String>(),
      clipboardDetectionEnabled: (fields[5] as bool?) ?? true,
      aiBaseUrl: (fields[6] as String?) ?? '',
      aiApiKey: (fields[7] as String?) ?? '',
      aiModel: (fields[8] as String?) ?? 'gpt-4o-mini',
      languageIndex: (fields[9] as num?)?.toInt() ?? 0,
      summaryVerbosityIndex: (fields[13] as num?)?.toInt() ?? 0,
      chatAnswerLengthIndex: (fields[14] as num?)?.toInt() ?? 0,
      chatKnowledgeSourceIndex: (fields[15] as num?)?.toInt() ?? 0,
      hideInboxTab: (fields[16] as bool?) ?? false,
      fontWeightIndex: (fields[17] as num?)?.toInt() ?? 0,
      startupTabIndex: (fields[18] as num?)?.toInt() ?? 0,
      memorySortNewestFirst: (fields[21] as bool?) ?? true,
      firstLaunchMs: fields[19] as int?,
      totalTokensUsed: (fields[20] as num?)?.toInt() ?? 0,
      embeddingBaseUrl: (fields[10] as String?) ?? '',
      embeddingApiKey: (fields[11] as String?) ?? '',
      embeddingModel: (fields[12] as String?) ?? '',
    );
  }

  @override
  void write(BinaryWriter writer, AppSettings obj) {
    writer
      ..writeByte(22)
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
      ..write(obj.languageIndex)
      ..writeByte(10)
      ..write(obj.embeddingBaseUrl)
      ..writeByte(11)
      ..write(obj.embeddingApiKey)
      ..writeByte(12)
      ..write(obj.embeddingModel)
      ..writeByte(13)
      ..write(obj.summaryVerbosityIndex)
      ..writeByte(14)
      ..write(obj.chatAnswerLengthIndex)
      ..writeByte(15)
      ..write(obj.chatKnowledgeSourceIndex)
      ..writeByte(16)
      ..write(obj.hideInboxTab)
      ..writeByte(17)
      ..write(obj.fontWeightIndex)
      ..writeByte(18)
      ..write(obj.startupTabIndex)
      ..writeByte(19)
      ..write(obj.firstLaunchMs)
      ..writeByte(20)
      ..write(obj.totalTokensUsed)
      ..writeByte(21)
      ..write(obj.memorySortNewestFirst);
  }
}
