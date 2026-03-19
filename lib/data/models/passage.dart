import 'package:hive/hive.dart';
import 'source_platform.dart';

class Passage extends HiveObject {
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

  Passage({
    required this.id,
    required this.url,
    required this.title,
    required this.source,
    this.tags = const [],
    this.notes = '',
    DateTime? createdAt,
    DateTime? updatedAt,
    this.isFavorite = false,
  })  : createdAt = createdAt ?? DateTime.now(),
        updatedAt = updatedAt ?? DateTime.now();

  Passage copyWith({
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
    return Passage(
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

class PassageAdapter extends TypeAdapter<Passage> {
  @override
  final int typeId = Passage.typeId;

  @override
  Passage read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return Passage(
      id: fields[0] as String,
      url: fields[1] as String,
      title: fields[2] as String,
      source: SourcePlatform.values[fields[3] as int],
      tags: (fields[4] as List).cast<String>(),
      notes: fields[5] as String,
      createdAt: fields[6] as DateTime,
      updatedAt: fields[7] as DateTime,
      isFavorite: fields[8] as bool,
    );
  }

  @override
  void write(BinaryWriter writer, Passage obj) {
    writer
      ..writeByte(9)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.url)
      ..writeByte(2)
      ..write(obj.title)
      ..writeByte(3)
      ..write(obj.source.index)
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
    return SourcePlatform.values[reader.readByte()];
  }

  @override
  void write(BinaryWriter writer, SourcePlatform obj) {
    writer.writeByte(obj.index);
  }
}
