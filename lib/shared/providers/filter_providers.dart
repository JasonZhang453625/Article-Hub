import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../data/models/filter_group.dart';
import 'passage_providers.dart';

final filterGroupsProvider =
    StateNotifierProvider<FilterGroupsNotifier, AsyncValue<List<FilterGroup>>>(
      (ref) {
        return FilterGroupsNotifier(ref);
      },
    );

class FilterGroupsNotifier
    extends StateNotifier<AsyncValue<List<FilterGroup>>> {
  static const String _boxName = 'filter_groups';

  final Ref _ref;
  Box<FilterGroup>? _box;

  FilterGroupsNotifier(this._ref) : super(const AsyncValue.loading()) {
    _load();
  }

  Future<void> _load() async {
    await _ref.read(hiveInitProvider.future);
    _box ??= await Hive.openBox<FilterGroup>(_boxName);
    state = AsyncValue.data(_box!.values.toList());
  }

  Future<void> add(FilterGroup group) async {
    _box ??= await Hive.openBox<FilterGroup>(_boxName);
    await _box!.put(group.id, group);
    state = AsyncValue.data(_box!.values.toList());
  }

  Future<void> update(FilterGroup group) async {
    _box ??= await Hive.openBox<FilterGroup>(_boxName);
    await _box!.put(group.id, group);
    state = AsyncValue.data(_box!.values.toList());
  }

  Future<void> delete(String id) async {
    _box ??= await Hive.openBox<FilterGroup>(_boxName);
    await _box!.delete(id);
    state = AsyncValue.data(_box!.values.toList());
  }

  String generateId() => const Uuid().v4();
}

/// The currently selected custom filter group ID. Empty string = none.
final selectedFilterGroupProvider = StateProvider<String>((ref) => '');
