import 'package:hive/hive.dart';
import 'memory_document.dart';
import 'source_platform.dart';

enum ProcessingStatus { pending, processing, completed, failed }

enum ProcessingStage {
  metadata,
  content,
  summary,
  tags,
  folderSuggestion,
  indexing,
}

class Article extends HiveObject {
  static const int typeId = 0;

  String id;
  String url;
  String title;
  SourcePlatform source;
  List<String> tags;
  String notes;
  DateTime createdAt;
  DateTime updatedAt;
  bool isFavorite;

  /// Optional cover image URL (e.g. from og:image). Null when unavailable.
  String? coverImageUrl;

  /// AI-generated summary of the article content. Null when not yet summarized.
  /// Legacy compatibility field. New writes use [memory].
  String? summary;

  /// Canonical structured memory. Stored as a JSON-compatible map in Hive.
  MemoryDocument? memory;

  /// User feedback on the AI summary: `null` = not yet rated, `1` = upvote
  /// (helpful), `-1` = downvote (not helpful). Reset to null when the summary
  /// is regenerated, since the content changed and old feedback no longer
  /// applies. Serves as a real-user signal for evaluating AI output quality.
  int? summaryFeedback;

  /// ID of the folder this article belongs to. Null means unfiled.
  String? folderId;

  ProcessingStatus processingStatus;
  ProcessingStage? processingStage;
  String? processingError;
  int retryCount;
  DateTime? lastProcessedAt;
  String? suggestedFolderId;

  /// True when the knowledge text is the extracted full page body
  /// (full-text save), false when it is an AI-generated summary.
  bool isFullText;

  bool get isLocalImage =>
      localMimeType != null &&
      localMimeType!.toLowerCase().startsWith('image/');

  bool get isLocalPdf =>
      localMimeType != null &&
      localMimeType!.toLowerCase() == 'application/pdf';

  bool get isLocalAttachment => localFilePath != null;

  bool get hasMemory => retrievalText.trim().isNotEmpty;

  String get displayMemoryMarkdown =>
      memory?.toMarkdown() ?? summary?.trim() ?? '';

  String get retrievalText =>
      memory?.toRetrievalText() ?? summary?.trim() ?? '';

  /// App-owned relative path under ApplicationSupport for a local attachment
  /// (e.g. imported image). Null for URL articles.
  String? localFilePath;

  /// MIME type of [localFilePath], e.g. image/jpeg. Null for URL articles.
  String? localMimeType;

  Article({
    required this.id,
    required this.url,
    required this.title,
    required this.source,
    this.tags = const [],
    this.notes = '',
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isFavorite = false,
    this.coverImageUrl,
    this.summary,
    this.memory,
    this.summaryFeedback,
    this.folderId,
    this.processingStatus = ProcessingStatus.completed,
    this.processingStage,
    this.processingError,
    this.retryCount = 0,
    this.lastProcessedAt,
    this.suggestedFolderId,
    this.isFullText = false,
    this.localFilePath,
    this.localMimeType,
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

  /// Sentinel used to distinguish "argument omitted" from "explicitly set to
  /// null" in [copyWith] for nullable fields. Passing [clearValue] for a
  /// nullable parameter clears it; omitting it leaves the field unchanged.
  ///
  /// Note: these must be instances of a dedicated type, not bare
  /// `const Object()` — Dart canonicalizes all `const Object()` literals to a
  /// single instance, which would make the two sentinels `identical`.
  static const Object _unset = _Sentinel('unset');

  /// Pass this for a nullable [copyWith] parameter to clear it to null.
  static const Object clearValue = _Sentinel('clear');

  Article copyWith({
    String? id,
    String? url,
    String? title,
    SourcePlatform? source,
    List<String>? tags,
    String? notes,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? isFavorite,
    Object? coverImageUrl = _unset,
    Object? summary = _unset,
    Object? memory = _unset,
    Object? summaryFeedback = _unset,
    Object? folderId = _unset,
    ProcessingStatus? processingStatus,
    Object? processingStage = _unset,
    Object? processingError = _unset,
    int? retryCount,
    Object? lastProcessedAt = _unset,
    Object? suggestedFolderId = _unset,
    bool? isFullText,
    Object? localFilePath = _unset,
    Object? localMimeType = _unset,
  }) {
    return Article(
      id: id ?? this.id,
      url: url ?? this.url,
      title: title ?? this.title,
      source: source ?? this.source,
      tags: tags ?? this.tags,
      notes: notes ?? this.notes,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      isFavorite: isFavorite ?? this.isFavorite,
      coverImageUrl: identical(coverImageUrl, _unset)
          ? this.coverImageUrl
          : (identical(coverImageUrl, clearValue)
                ? null
                : coverImageUrl as String?),
      summary: identical(summary, _unset)
          ? this.summary
          : (identical(summary, clearValue) ? null : summary as String?),
      memory: identical(memory, _unset)
          ? this.memory
          : (identical(memory, clearValue) ? null : memory as MemoryDocument?),
      summaryFeedback: identical(summaryFeedback, _unset)
          ? this.summaryFeedback
          : (identical(summaryFeedback, clearValue)
                ? null
                : summaryFeedback as int?),
      folderId: identical(folderId, _unset)
          ? this.folderId
          : (identical(folderId, clearValue) ? null : folderId as String?),
      processingStatus: processingStatus ?? this.processingStatus,
      processingStage: identical(processingStage, _unset)
          ? this.processingStage
          : (identical(processingStage, clearValue)
                ? null
                : processingStage as ProcessingStage?),
      processingError: identical(processingError, _unset)
          ? this.processingError
          : (identical(processingError, clearValue)
                ? null
                : processingError as String?),
      retryCount: retryCount ?? this.retryCount,
      lastProcessedAt: identical(lastProcessedAt, _unset)
          ? this.lastProcessedAt
          : (identical(lastProcessedAt, clearValue)
                ? null
                : lastProcessedAt as DateTime?),
      suggestedFolderId: identical(suggestedFolderId, _unset)
          ? this.suggestedFolderId
          : (identical(suggestedFolderId, clearValue)
                ? null
                : suggestedFolderId as String?),
      isFullText: isFullText ?? this.isFullText,
      localFilePath: identical(localFilePath, _unset)
          ? this.localFilePath
          : (identical(localFilePath, clearValue)
                ? null
                : localFilePath as String?),
      localMimeType: identical(localMimeType, _unset)
          ? this.localMimeType
          : (identical(localMimeType, clearValue)
                ? null
                : localMimeType as String?),
    );
  }

  /// Serializes the article to the versioned nested storage/sync schema.
  Map<String, dynamic> toJson() {
    final exportedMemory =
        memory ??
        (summary != null && summary!.trim().isNotEmpty
            ? (isFullText
                  ? MemoryDocument.fullText(
                      body: summary!,
                      format: localMimeType == 'text/markdown'
                          ? 'markdown'
                          : 'plain',
                    )
                  : MemoryDocument.legacyMarkdown(body: summary!))
            : null);
    return {
      'schemaVersion': 1,
      'id': id,
      'title': title,
      'tags': tags,
      'source': {
        'kind': isLocalAttachment ? 'local_file' : 'url',
        'platform': source.name,
        'uri': url,
        'coverImageUri': coverImageUrl,
        'mimeType': localMimeType,
        'localPath': localFilePath,
      },
      'memory': exportedMemory?.toContentJson(),
      'userState': {
        'notes': notes,
        'favorite': isFavorite,
        'folderId': folderId,
        'feedback': summaryFeedback,
      },
      'processing': {
        'status': processingStatus.name,
        'stage': processingStage?.name,
        'error': processingError,
        'retryCount': retryCount,
        'lastProcessedAt': lastProcessedAt?.toIso8601String(),
        'suggestedFolderId': suggestedFolderId,
      },
      'generation': exportedMemory?.generation?.toJson(),
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
    };
  }

  /// Rebuilds an article from a [toJson] map. Throws [FormatException] if the
  /// required fields are missing or malformed.
  factory Article.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final sourceJson = _mapOf(json['source']);
    final userState = _mapOf(json['userState']);
    final processing = _mapOf(json['processing']);
    final generation = _mapOf(json['generation']);
    final memoryJson = _mapOf(json['memory']);
    final url = json['url'] is String ? json['url'] : sourceJson?['uri'];
    if (id is! String || url is! String) {
      throw const FormatException('Article is missing required fields');
    }
    MemoryDocument? memory;
    String? legacySummary = json['summary'] is String
        ? json['summary'] as String
        : null;
    final legacyIsFullText = json['isFullText'] == true;
    if (memoryJson != null) {
      if (generation != null) {
        memoryJson['generation'] = generation;
      }
      memory = MemoryDocument.fromJson(memoryJson);
      legacySummary = null;
    } else if (legacySummary != null && legacySummary.trim().isNotEmpty) {
      final mimeType = sourceJson?['mimeType'] ?? json['localMimeType'];
      memory = legacyIsFullText
          ? MemoryDocument.fullText(
              body: legacySummary,
              format: mimeType == 'text/markdown' ? 'markdown' : 'plain',
            )
          : MemoryDocument.legacyMarkdown(body: legacySummary);
      legacySummary = null;
    }
    return Article(
      id: id,
      url: url,
      title: json['title'] is String ? json['title'] as String : url,
      source: _sourceFromJson(json['source'], sourceJson),
      tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
      notes: userState?['notes'] is String
          ? userState!['notes'] as String
          : (json['notes'] is String ? json['notes'] as String : ''),
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
      isFavorite: userState?['favorite'] == true || json['isFavorite'] == true,
      coverImageUrl: sourceJson?['coverImageUri'] is String
          ? sourceJson!['coverImageUri'] as String
          : (json['coverImageUrl'] is String
                ? json['coverImageUrl'] as String
                : null),
      summary: legacySummary,
      memory: memory,
      summaryFeedback: userState?['feedback'] is int
          ? userState!['feedback'] as int
          : (json['summaryFeedback'] is int
                ? json['summaryFeedback'] as int
                : null),
      folderId: userState?['folderId'] is String
          ? userState!['folderId'] as String
          : (json['folderId'] is String ? json['folderId'] as String : null),
      processingStatus: _processingStatusFromJson(
        processing?['status'] ?? json['processingStatus'],
      ),
      processingStage: _processingStageFromJson(
        processing?['stage'] ?? json['processingStage'],
      ),
      processingError: processing?['error'] is String
          ? processing!['error'] as String
          : (json['processingError'] is String
                ? json['processingError'] as String
                : null),
      retryCount: processing?['retryCount'] is int
          ? processing!['retryCount'] as int
          : (json['retryCount'] is int ? json['retryCount'] as int : 0),
      lastProcessedAt: _optionalDate(
        processing?['lastProcessedAt'] ?? json['lastProcessedAt'],
      ),
      suggestedFolderId: processing?['suggestedFolderId'] is String
          ? processing!['suggestedFolderId'] as String
          : (json['suggestedFolderId'] is String
                ? json['suggestedFolderId'] as String
                : null),
      isFullText: memory?.kind == MemoryKind.fullText || legacyIsFullText,
      localFilePath: sourceJson?['localPath'] is String
          ? sourceJson!['localPath'] as String
          : (json['localFilePath'] is String
                ? json['localFilePath'] as String
                : null),
      localMimeType: sourceJson?['mimeType'] is String
          ? sourceJson!['mimeType'] as String
          : (json['localMimeType'] is String
                ? json['localMimeType'] as String
                : null),
    );
  }

  static DateTime? _optionalDate(dynamic value) {
    return value is String ? DateTime.tryParse(value) : null;
  }

  static DateTime _parseDate(dynamic value) {
    if (value is String) {
      return DateTime.tryParse(value) ?? DateTime.now();
    }
    return DateTime.now();
  }
}

class ArticleAdapter extends TypeAdapter<Article> {
  @override
  final int typeId = Article.typeId;

  @override
  Article read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return Article(
      id: fields[0] as String,
      url: fields[1] as String,
      title: fields[2] as String,
      source: SourcePlatformAdapter.fromStoredValue(fields[3] as int),
      tags: (fields[4] as List).cast<String>(),
      notes: fields[5] as String,
      createdAt: fields[6] as DateTime,
      updatedAt: fields[7] as DateTime,
      isFavorite: fields[8] as bool,
      coverImageUrl: fields[9] as String?,
      summary: fields[10] as String?,
      // Field 12 added after folderId (11); absent on older records → null.
      summaryFeedback: fields[12] as int?,
      folderId: fields[11] as String?,
      // Fields 13-18 added for processing state machine; absent on older
      // records → sensible defaults (completed, no stage/error/retries).
      processingStatus: fields[13] is int
          ? ProcessingStatus.values[fields[13] as int]
          : ProcessingStatus.completed,
      processingStage: fields[14] is int
          ? ProcessingStage.values[fields[14] as int]
          : null,
      processingError: fields[15] as String?,
      retryCount: fields[16] is int ? fields[16] as int : 0,
      lastProcessedAt: fields[17] as DateTime?,
      suggestedFolderId: fields[18] as String?,
      isFullText: fields[19] as bool? ?? false,
      localFilePath: fields[20] as String?,
      localMimeType: fields[21] as String?,
      memory: fields[22] is Map
          ? MemoryDocument.fromJson(fields[22] as Map)
          : null,
    );
  }

  @override
  void write(BinaryWriter writer, Article obj) {
    writer
      ..writeByte(23)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.url)
      ..writeByte(2)
      ..write(obj.title)
      ..writeByte(3)
      ..write(SourcePlatformAdapter.toStoredValue(obj.source))
      ..writeByte(4)
      ..write(obj.tags)
      ..writeByte(5)
      ..write(obj.notes)
      ..writeByte(6)
      ..write(obj.createdAt)
      ..writeByte(7)
      ..write(obj.updatedAt)
      ..writeByte(8)
      ..write(obj.isFavorite)
      ..writeByte(9)
      ..write(obj.coverImageUrl)
      ..writeByte(10)
      ..write(obj.summary)
      ..writeByte(11)
      ..write(obj.folderId)
      ..writeByte(12)
      ..write(obj.summaryFeedback)
      ..writeByte(13)
      ..write(obj.processingStatus.index)
      ..writeByte(14)
      ..write(obj.processingStage?.index)
      ..writeByte(15)
      ..write(obj.processingError)
      ..writeByte(16)
      ..write(obj.retryCount)
      ..writeByte(17)
      ..write(obj.lastProcessedAt)
      ..writeByte(18)
      ..write(obj.suggestedFolderId)
      ..writeByte(19)
      ..write(obj.isFullText)
      ..writeByte(20)
      ..write(obj.localFilePath)
      ..writeByte(21)
      ..write(obj.localMimeType)
      ..writeByte(22)
      ..write(obj.memory?.toJson());
  }
}

Map<dynamic, dynamic>? _mapOf(dynamic value) => value is Map ? value : null;

SourcePlatform _sourceFromJson(
  dynamic rawSource,
  Map<dynamic, dynamic>? sourceJson,
) {
  if (rawSource is int) {
    return SourcePlatformAdapter.fromStoredValue(rawSource);
  }
  final platform = sourceJson?['platform'];
  if (platform is String) {
    return SourcePlatform.values.firstWhere(
      (value) => value.name == platform,
      orElse: () => SourcePlatform.web,
    );
  }
  return SourcePlatform.web;
}

ProcessingStatus _processingStatusFromJson(dynamic value) {
  if (value is int && value >= 0 && value < ProcessingStatus.values.length) {
    return ProcessingStatus.values[value];
  }
  if (value is String) {
    return ProcessingStatus.values.firstWhere(
      (status) => status.name == value,
      orElse: () => ProcessingStatus.completed,
    );
  }
  return ProcessingStatus.completed;
}

ProcessingStage? _processingStageFromJson(dynamic value) {
  if (value is int && value >= 0 && value < ProcessingStage.values.length) {
    return ProcessingStage.values[value];
  }
  if (value is String) {
    for (final stage in ProcessingStage.values) {
      if (stage.name == value) return stage;
    }
  }
  return null;
}

class SourcePlatformAdapter extends TypeAdapter<SourcePlatform> {
  @override
  final int typeId = 1;

  @override
  SourcePlatform read(BinaryReader reader) {
    return fromStoredValue(reader.readByte());
  }

  @override
  void write(BinaryWriter writer, SourcePlatform obj) {
    writer.writeByte(toStoredValue(obj));
  }

  static SourcePlatform fromStoredValue(int value) {
    switch (value) {
      case 0:
        return SourcePlatform.wechat;
      case 1:
        return SourcePlatform.zhihu;
      case 2:
        return SourcePlatform.web;
      case 3:
        return SourcePlatform.x;
      case 4:
        return SourcePlatform.bilibili;
      case 5:
        return SourcePlatform.xiaohongshu;
      case 6:
        return SourcePlatform.chatgpt;
      case 7:
        return SourcePlatform.youtube;
      case 8:
      case 9:
        return SourcePlatform.web;
      case 10:
        return SourcePlatform.reddit;
      case 11:
        return SourcePlatform.local;
      default:
        return SourcePlatform.web;
    }
  }

  static int toStoredValue(SourcePlatform platform) {
    switch (platform) {
      case SourcePlatform.wechat:
        return 0;
      case SourcePlatform.zhihu:
        return 1;
      case SourcePlatform.web:
        return 2;
      case SourcePlatform.x:
        return 3;
      case SourcePlatform.bilibili:
        return 4;
      case SourcePlatform.xiaohongshu:
        return 5;
      case SourcePlatform.chatgpt:
        return 6;
      case SourcePlatform.youtube:
        return 7;
      case SourcePlatform.reddit:
        return 10;
      case SourcePlatform.local:
        return 11;
    }
  }
}

/// Distinct sentinel type for [Article.copyWith]. A dedicated class guarantees
/// each `const _Sentinel(...)` is a unique instance, unlike bare
/// `const Object()` which Dart canonicalizes to a single shared instance.
class _Sentinel {
  final String _name;
  const _Sentinel(this._name);
  @override
  String toString() => '_Sentinel($_name)';
}
