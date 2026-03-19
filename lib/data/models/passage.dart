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
  }) : createdAt = createdAt ?? DateTime.now(),
       updatedAt = updatedAt ?? DateTime.now();

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
    );
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
    );
  }

  @override
  void write(BinaryWriter writer, Article obj) {
    writer
      ..writeByte(9)
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
      ..write(obj.isFavorite);
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
