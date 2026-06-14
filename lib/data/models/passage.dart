import 'package:hive/hive.dart';
import 'source_platform.dart';

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
  String? summary;

  /// ID of the folder this article belongs to. Null means unfiled.
  String? folderId;

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
    this.folderId,
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
    Object? folderId = _unset,
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
      folderId: identical(folderId, _unset)
          ? this.folderId
          : (identical(folderId, clearValue) ? null : folderId as String?),
    );
  }

  /// Serializes the article to a JSON-compatible map. The source platform is
  /// stored as its stable integer value so the format stays robust against
  /// enum reordering (same mapping used by the Hive adapter).
  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'url': url,
      'title': title,
      'source': SourcePlatformAdapter.toStoredValue(source),
      'tags': tags,
      'notes': notes,
      'createdAt': createdAt.toIso8601String(),
      'updatedAt': updatedAt.toIso8601String(),
      'isFavorite': isFavorite,
      'coverImageUrl': coverImageUrl,
      'summary': summary,
      'folderId': folderId,
    };
  }

  /// Rebuilds an article from a [toJson] map. Throws [FormatException] if the
  /// required fields are missing or malformed.
  factory Article.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final url = json['url'];
    if (id is! String || url is! String) {
      throw const FormatException('Article is missing required fields');
    }
    return Article(
      id: id,
      url: url,
      title: json['title'] is String ? json['title'] as String : url,
      source: SourcePlatformAdapter.fromStoredValue(
        json['source'] is int ? json['source'] as int : 2,
      ),
      tags: (json['tags'] as List?)?.whereType<String>().toList() ?? const [],
      notes: json['notes'] is String ? json['notes'] as String : '',
      createdAt: _parseDate(json['createdAt']),
      updatedAt: _parseDate(json['updatedAt']),
      isFavorite: json['isFavorite'] == true,
      coverImageUrl:
          json['coverImageUrl'] is String ? json['coverImageUrl'] as String : null,
      summary: json['summary'] is String ? json['summary'] as String : null,
      folderId: json['folderId'] is String ? json['folderId'] as String : null,
    );
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
      folderId: fields[11] as String?,
    );
  }

  @override
  void write(BinaryWriter writer, Article obj) {
    writer
      ..writeByte(12)
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
      ..write(obj.folderId);
  }
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
        return SourcePlatform.medium;
      case 9:
        return SourcePlatform.substack;
      case 10:
        return SourcePlatform.reddit;
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
      case SourcePlatform.medium:
        return 8;
      case SourcePlatform.substack:
        return 9;
      case SourcePlatform.reddit:
        return 10;
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
