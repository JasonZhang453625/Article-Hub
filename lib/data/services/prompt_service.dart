import 'package:flutter/services.dart' show rootBundle;

class PromptService {
  static const _basePath = 'assets/prompts';

  final Map<String, String> _cache = {};

  Future<String> load(String path, [Map<String, String>? vars]) async {
    final fullPath = '$_basePath/$path';
    var content = _cache[fullPath];
    if (content == null) {
      content = await rootBundle.loadString(fullPath);
      _cache[fullPath] = content;
    }

    if (vars != null && vars.isNotEmpty) {
      for (final entry in vars.entries) {
        content = content!.replaceAll('{{${entry.key}}}', entry.value);
      }
    }

    return content!;
  }
}
