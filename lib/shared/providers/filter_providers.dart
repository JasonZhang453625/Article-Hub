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
    try {
      await _ref.read(hiveInitProvider.future);
      _box ??= await Hive.openBox<FilterGroup>(_boxName);
      state = AsyncValue.data(_box!.values.toList());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<Box<FilterGroup>> _ensureBox() async {
    await _ref.read(hiveInitProvider.future);
    return _box ??= await Hive.openBox<FilterGroup>(_boxName);
  }

  Future<void> add(FilterGroup group) async {
    try {
      final box = await _ensureBox();
      await box.put(group.id, group);
      state = AsyncValue.data(box.values.toList());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> update(FilterGroup group) async {
    try {
      final box = await _ensureBox();
      await box.put(group.id, group);
      state = AsyncValue.data(box.values.toList());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  Future<void> delete(String id) async {
    try {
      final box = await _ensureBox();
      await box.delete(id);
      state = AsyncValue.data(box.values.toList());
    } catch (e, st) {
      state = AsyncValue.error(e, st);
    }
  }

  /// Merges imported filter groups (by id) into the box.
  Future<int> importAll(Iterable<FilterGroup> groups) async {
    try {
      final entries = {for (final g in groups) g.id: g};
      if (entries.isEmpty) return 0;
      final box = await _ensureBox();
      await box.putAll(entries);
      state = AsyncValue.data(box.values.toList());
      return entries.length;
    } catch (e, st) {
      state = AsyncValue.error(e, st);
      return 0;
    }
  }

  String generateId() => const Uuid().v4();
}

/// The currently selected custom filter group ID. Empty string = none.
final selectedFilterGroupProvider = StateProvider<String>((ref) => '');
