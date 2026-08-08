import 'package:flutter/material.dart';
import 'package:hive/hive.dart';

import 'source_platform.dart';

class AppSettings {
  static const int typeId = 2;

  static const String defaultHostedTextModel = 'mimo-v2.5';
  static const String defaultHostedVisionModel = 'sensenova-6.7-flash-lite';
  static const List<String> hostedTextModels = ['mimo-v2.5', 'mimo-v2.5-pro'];
  static const List<String> hostedVisionModels = [
    'mimo-v2.5',
    'sensenova-6.7-flash-lite',
  ];

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
  /// The API key is stored locally on the device and sent directly to the
  /// user's chosen AI provider. Account sync also carries it as JSON over
  /// HTTPS. We deliberately do NOT
  /// additionally encrypt it: the threat model is "attacker has the unlocked
  /// device or root access", against which app-level encryption provides no
  /// real protection (the decryption path lives in the same app). The one
  /// protection that does matter is controlling which serialization path is
  /// used: [toJson] excludes the key, while the user-requested full backup and
  /// complete account sync use [toBackupJson] and [toSyncJson].
  /// See `docs/PRD.md` (AI key storage decision) for the full rationale.
  String aiBaseUrl;
  String aiApiKey;
  String aiModel;

  /// AI configuration for knowledge-base chat (BYOK).
  String chatAiBaseUrl;
  String chatAiApiKey;
  String chatAiModel;

  /// AI configuration for image understanding (BYOK).
  String imageAiBaseUrl;
  String imageAiApiKey;
  String imageAiModel;

  /// AI provider mode: 0 = BYOK (direct connection with the user's own key),
  /// 1 = hosted (requests are proxied through the Memora backend).
  int aiProviderMode;

  /// Backend-hosted model id used when [aiProviderMode] is hosted.
  String hostedAiModel;

  /// Backend-hosted model ids for chat and image understanding.
  String hostedChatModel;
  String hostedVisionModel;

  /// Embedding configuration for semantic search / RAG (BYOK).
  ///
  /// Follows the same threat model as [aiApiKey]. Generic [toJson] output omits
  /// the key; complete backups and account sync include it via
  /// [toBackupJson] and [toSyncJson].
  String embeddingBaseUrl;
  String embeddingApiKey;
  String embeddingModel;

  /// Tavily API key for the RAG chat web-search fallback (BYOK).
  ///
  /// Same threat model as [aiApiKey]: omitted from generic [toJson], included
  /// in [toBackupJson] / [toSyncJson].
  String tavilyApiKey;

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

  /// When true, the app automatically syncs changes to the cloud when logged
  /// in (on launch, app resume, or connectivity regain). When false, only
  /// manual sync via the account screen runs.
  bool cloudSyncEnabled;

  AppSettings({
    this.fontSize = 14.0,
    this.webZoomPercent = 100,
    this.themeModeIndex = 1,
    this.clipboardDetectionEnabled = true,
    this.aiBaseUrl = '',
    this.aiApiKey = '',
    this.aiModel = 'gpt-4o-mini',
    this.chatAiBaseUrl = '',
    this.chatAiApiKey = '',
    this.chatAiModel = 'gpt-4o-mini',
    this.imageAiBaseUrl = '',
    this.imageAiApiKey = '',
    this.imageAiModel = 'mimo-v2.5',
    this.aiProviderMode = 0,
    this.hostedAiModel = defaultHostedTextModel,
    this.hostedChatModel = defaultHostedTextModel,
    this.hostedVisionModel = defaultHostedVisionModel,
    this.embeddingBaseUrl = '',
    this.embeddingApiKey = '',
    this.embeddingModel = '',
    this.tavilyApiKey = '',
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
    this.cloudSyncEnabled = false,
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
    String? chatAiBaseUrl,
    String? chatAiApiKey,
    String? chatAiModel,
    String? imageAiBaseUrl,
    String? imageAiApiKey,
    String? imageAiModel,
    int? aiProviderMode,
    String? hostedAiModel,
    String? hostedChatModel,
    String? hostedVisionModel,
    String? embeddingBaseUrl,
    String? embeddingApiKey,
    String? embeddingModel,
    String? tavilyApiKey,
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
    bool? cloudSyncEnabled,
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
      chatAiBaseUrl: chatAiBaseUrl ?? this.chatAiBaseUrl,
      chatAiApiKey: chatAiApiKey ?? this.chatAiApiKey,
      chatAiModel: chatAiModel ?? this.chatAiModel,
      imageAiBaseUrl: imageAiBaseUrl ?? this.imageAiBaseUrl,
      imageAiApiKey: imageAiApiKey ?? this.imageAiApiKey,
      imageAiModel: imageAiModel ?? this.imageAiModel,
      aiProviderMode: aiProviderMode ?? this.aiProviderMode,
      hostedAiModel: hostedAiModel ?? this.hostedAiModel,
      hostedChatModel: hostedChatModel ?? this.hostedChatModel,
      hostedVisionModel: hostedVisionModel ?? this.hostedVisionModel,
      embeddingBaseUrl: embeddingBaseUrl ?? this.embeddingBaseUrl,
      embeddingApiKey: embeddingApiKey ?? this.embeddingApiKey,
      embeddingModel: embeddingModel ?? this.embeddingModel,
      tavilyApiKey: tavilyApiKey ?? this.tavilyApiKey,
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
      cloudSyncEnabled: cloudSyncEnabled ?? this.cloudSyncEnabled,
      sourcePlatformOrder: sourcePlatformOrder ?? this.sourcePlatformOrder,
      hiddenSourcePlatforms:
          hiddenSourcePlatforms ?? this.hiddenSourcePlatforms,
    );
  }

  /// Serializes settings without provider secrets.
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
      'chatAiBaseUrl': chatAiBaseUrl,
      'chatAiModel': chatAiModel,
      'imageAiBaseUrl': imageAiBaseUrl,
      'imageAiModel': imageAiModel,
      'aiProviderMode': aiProviderMode,
      'hostedAiModel': hostedAiModel,
      'hostedChatModel': hostedChatModel,
      'hostedVisionModel': hostedVisionModel,
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
      'cloudSyncEnabled': cloudSyncEnabled,
      'sourcePlatformOrder': sourcePlatformOrder,
      'hiddenSourcePlatforms': hiddenSourcePlatforms,
    };
  }

  /// Serializes every setting needed to restore a complete local backup,
  /// including both provider API keys and their base URL/model selections.
  Map<String, dynamic> toBackupJson() {
    return {
      ...toJson(),
      'aiApiKey': aiApiKey,
      'chatAiApiKey': chatAiApiKey,
      'imageAiApiKey': imageAiApiKey,
      'embeddingApiKey': embeddingApiKey,
      'tavilyApiKey': tavilyApiKey,
    };
  }

  /// Serializes the complete cross-device configuration. This map contains
  /// provider secrets and is sent to the account sync API as JSON over HTTPS.
  /// It must never be written to application or server logs.
  Map<String, dynamic> toSyncJson() {
    return {'schemaVersion': 1, ...toBackupJson()};
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
      chatAiBaseUrl: json['chatAiBaseUrl'] is String
          ? json['chatAiBaseUrl'] as String
          : (json['aiBaseUrl'] is String ? json['aiBaseUrl'] as String : ''),
      chatAiApiKey: json['chatAiApiKey'] is String
          ? json['chatAiApiKey'] as String
          : (json['aiApiKey'] is String ? json['aiApiKey'] as String : ''),
      chatAiModel: json['chatAiModel'] is String
          ? json['chatAiModel'] as String
          : (json['aiModel'] is String
                ? json['aiModel'] as String
                : 'gpt-4o-mini'),
      imageAiBaseUrl: json['imageAiBaseUrl'] is String
          ? json['imageAiBaseUrl'] as String
          : '',
      imageAiApiKey: json['imageAiApiKey'] is String
          ? json['imageAiApiKey'] as String
          : '',
      imageAiModel: json['imageAiModel'] is String
          ? json['imageAiModel'] as String
          : 'mimo-v2.5',
      aiProviderMode: (json['aiProviderMode'] as num?)?.toInt() == 1 ? 1 : 0,
      hostedAiModel: json['hostedAiModel'] is String
          ? json['hostedAiModel'] as String
          : defaultHostedTextModel,
      hostedChatModel: json['hostedChatModel'] is String
          ? json['hostedChatModel'] as String
          : (json['hostedAiModel'] is String
                ? json['hostedAiModel'] as String
                : defaultHostedTextModel),
      hostedVisionModel: json['hostedVisionModel'] is String
          ? json['hostedVisionModel'] as String
          : defaultHostedVisionModel,
      embeddingBaseUrl: json['embeddingBaseUrl'] is String
          ? json['embeddingBaseUrl'] as String
          : '',
      embeddingApiKey: json['embeddingApiKey'] is String
          ? json['embeddingApiKey'] as String
          : '',
      embeddingModel: json['embeddingModel'] is String
          ? json['embeddingModel'] as String
          : '',
      tavilyApiKey: json['tavilyApiKey'] is String
          ? json['tavilyApiKey'] as String
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
      cloudSyncEnabled: json['cloudSyncEnabled'] is bool
          ? json['cloudSyncEnabled'] as bool
          : false,
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
      tavilyApiKey: (fields[22] as String?) ?? '',
      aiProviderMode: (fields[23] as num?)?.toInt() == 1 ? 1 : 0,
      hostedAiModel:
          (fields[24] as String?) ?? AppSettings.defaultHostedTextModel,
      chatAiBaseUrl: (fields[25] as String?) ?? (fields[6] as String?) ?? '',
      chatAiApiKey: (fields[26] as String?) ?? (fields[7] as String?) ?? '',
      chatAiModel:
          (fields[27] as String?) ?? (fields[8] as String?) ?? 'gpt-4o-mini',
      imageAiBaseUrl: (fields[28] as String?) ?? '',
      imageAiApiKey: (fields[29] as String?) ?? '',
      imageAiModel: (fields[30] as String?) ?? 'mimo-v2.5',
      hostedChatModel:
          (fields[31] as String?) ??
          (fields[24] as String?) ??
          AppSettings.defaultHostedTextModel,
      hostedVisionModel:
          (fields[32] as String?) ?? AppSettings.defaultHostedVisionModel,
      cloudSyncEnabled: (fields[33] as bool?) ?? false,
    );
  }

  @override
  void write(BinaryWriter writer, AppSettings obj) {
    writer
      ..writeByte(34)
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
      ..write(obj.memorySortNewestFirst)
      ..writeByte(22)
      ..write(obj.tavilyApiKey)
      ..writeByte(23)
      ..write(obj.aiProviderMode)
      ..writeByte(24)
      ..write(obj.hostedAiModel)
      ..writeByte(25)
      ..write(obj.chatAiBaseUrl)
      ..writeByte(26)
      ..write(obj.chatAiApiKey)
      ..writeByte(27)
      ..write(obj.chatAiModel)
      ..writeByte(28)
      ..write(obj.imageAiBaseUrl)
      ..writeByte(29)
      ..write(obj.imageAiApiKey)
      ..writeByte(30)
      ..write(obj.imageAiModel)
      ..writeByte(31)
      ..write(obj.hostedChatModel)
      ..writeByte(32)
      ..write(obj.hostedVisionModel)
      ..writeByte(33)
      ..write(obj.cloudSyncEnabled);
  }
}
