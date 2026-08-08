import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Incremented when the knowledge tab should return to the all-items top.
final homeScrollToTopRequestProvider = StateProvider<int>((ref) => 0);
