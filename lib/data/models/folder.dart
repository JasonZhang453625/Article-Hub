import 'package:hive/hive.dart';

class Folder extends HiveObject {
  static const int typeId = 4;

  String id;
  String name;
  String? parentId;
  int sortOrder;
  DateTime createdAt;

  Folder({
    required this.id,
    required this.name,
    this.parentId,
    this.sortOrder = 0,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  /// Sentinels for [copyWith] to distinguish "omitted" from "set to null".
  /// Must be a dedicated type, not bare `const Object()` — Dart canonicalizes
  /// all `const Object()` literals to one instance, breaking [identical].
  static const Object _unset = _Sentinel('unset');

  /// Pass this for [parentId] in [copyWith] to clear it (move to root).
  static const Object clearValue = _Sentinel('clear');

  Folder copyWith({
    String? id,
    String? name,
    Object? parentId = _unset,
    int? sortOrder,
  }) {
    return Folder(
      id: id ?? this.id,
      name: name ?? this.name,
      parentId: identical(parentId, _unset)
          ? this.parentId
          : (identical(parentId, clearValue) ? null : parentId as String?),
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'id': id,
      'name': name,
      'parentId': parentId,
      'sortOrder': sortOrder,
      'createdAt': createdAt.toIso8601String(),
    };
  }

  factory Folder.fromJson(Map<String, dynamic> json) {
    final id = json['id'];
    final name = json['name'];
    if (id is! String || name is! String) {
      throw const FormatException('Folder is missing required fields');
    }
    return Folder(
      id: id,
      name: name,
      parentId: json['parentId'] is String ? json['parentId'] as String : null,
      sortOrder: (json['sortOrder'] as num?)?.toInt() ?? 0,
      createdAt: json['createdAt'] is String
          ? DateTime.tryParse(json['createdAt'] as String) ?? DateTime.now()
          : DateTime.now(),
    );
  }
}

class FolderAdapter extends TypeAdapter<Folder> {
  @override
  final int typeId = Folder.typeId;

  @override
  Folder read(BinaryReader reader) {
    final numOfFields = reader.readByte();
    final fields = <int, dynamic>{};
    for (int i = 0; i < numOfFields; i++) {
      fields[reader.readByte()] = reader.read();
    }
    return Folder(
      id: fields[0] as String,
      name: fields[1] as String,
      parentId: fields[2] as String?,
      sortOrder: (fields[3] as int?) ?? 0,
      createdAt: fields[4] as DateTime,
    );
  }

  @override
  void write(BinaryWriter writer, Folder obj) {
    writer
      ..writeByte(5)
      ..writeByte(0)
      ..write(obj.id)
      ..writeByte(1)
      ..write(obj.name)
      ..writeByte(2)
      ..write(obj.parentId)
      ..writeByte(3)
      ..write(obj.sortOrder)
      ..writeByte(4)
      ..write(obj.createdAt);
  }
}

/// Distinct sentinel type for [Folder.copyWith]. A dedicated class guarantees
/// each `const _Sentinel(...)` is a unique instance, unlike bare
/// `const Object()` which Dart canonicalizes to a single shared instance.
class _Sentinel {
  final String _name;
  const _Sentinel(this._name);
  @override
  String toString() => '_Sentinel($_name)';
}
