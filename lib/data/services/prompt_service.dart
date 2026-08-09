import 'package:flutter/services.dart' show rootBundle;

class PromptService {
  static const _basePath = 'assets/prompts';
  static final RegExp _placeholder = RegExp(r'\{\{([A-Za-z][A-Za-z0-9_]*)\}\}');

  final Map<String, String> _cache = {};

  Future<String> load(String path, [Map<String, String>? vars]) async {
    final fullPath = '$_basePath/$path';
    var content = _cache[fullPath];
    if (content == null) {
      content = await rootBundle.loadString(fullPath);
      _cache[fullPath] = content;
    }

    if (vars == null || vars.isEmpty) return content;
    return content.replaceAllMapped(_placeholder, (match) {
      final key = match.group(1)!;
      return vars.containsKey(key) ? vars[key]! : match.group(0)!;
    });
  }
}
