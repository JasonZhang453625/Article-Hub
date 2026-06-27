import 'dart:async';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Exposes whether the device currently has network connectivity.
/// Updates automatically when connectivity changes.
final connectivityProvider = StreamProvider<bool>((ref) {
  final connectivity = Connectivity();
  final controller = StreamController<bool>();

  void emit(List<ConnectivityResult> results) {
    // On web / desktop, connectivity may report `vpn` or `other` as valid.
    final online = results.any((r) => r != ConnectivityResult.none);
    controller.add(online);
  }

  // Initial value.
  connectivity.checkConnectivity().then(emit);

  // Listen for changes.
  final sub = connectivity.onConnectivityChanged.listen(emit);
  ref.onDispose(() {
    sub.cancel();
    controller.close();
  });

  return controller.stream;
});
