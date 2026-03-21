import 'package:hive/hive.dart';

class FilterGroup {
  static const int typeId = 3;

  String id;
  String name;

  /// Tag keywords — articles must match at least one.
  List<String> tagPatterns;

  /// Source platform names — articles must match at least one.
  /// Empty means "any source".
  List<String> sourcePlatforms;

  FilterGroup({
    required this.id,
    required this.name,
    this.tagPatterns = const [],
    this.sourcePlatforms = const [],
  });

  FilterGroup copyWith({
    String? id,
    String? name,
    List<String>? tagPatterns,
    List<String>? sourcePlatforms,
  }) {
    return FilterGroup(
      id: id ?? this.id,
      name: name ?? this.name,
      tagPatterns: tagPatterns ?? this.tagPatterns,
      sourcePlatforms: sourcePlatforms ?? this.sourcePlatforms,
    );
  }
}

class FilterGroupAdapter extends TypeAdapter<FilterGroup> {
  @override
  final int typeId = FilterGroup.typeId;

  @override
  FilterGroup read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return FilterGroup(
      id: fields[0] as String,
      name: fields[1] as String,
      tagPatterns: (fields[2] as List?)?.cast<String>() ?? [],
      sourcePlatforms: (fields[3] as List?)?.cast<String>() ?? [],
    );
  }

  @override
  void write(BinaryWriter writer, FilterGroup obj) {
    writer
      ..writeByte(4)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.tagPatterns)
      ..writeByte(3)
      ..write(obj.sourcePlatforms);
  }
}
