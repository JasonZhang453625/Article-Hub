import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app.dart';
import 'config/backend_config.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  BackendConfig.validate();

  runApp(const ProviderScope(child: App()));
}
