/// Conservative capability check used when a provider does not publish model
/// metadata. False negatives take the safe text-fallback path through the
/// separately configured vision model; false positives would fail a request.
bool chatModelSupportsImageInput(
  String model, {
  Iterable<String> declaredVisionModels = const [],
}) {
  final normalized = _normalizeModel(model);
  if (normalized.isEmpty) return false;
  final declared = declaredVisionModels
      .map(_normalizeModel)
      .where((candidate) => candidate.isNotEmpty)
      .toSet();
  if (declared.isNotEmpty) {
    return declared.contains(normalized);
  }
  if (normalized == 'mimo-v2.5' || normalized.endsWith('/mimo-v2.5')) {
    return true;
  }

  return RegExp(
    r'(?:gpt-4o|gpt-4\.1|gpt-5|o[134](?:[-.]|$)|claude-(?:3|4)|gemini|qwen[^/]*vl|sensenova)',
  ).hasMatch(normalized);
}

String _normalizeModel(String model) => model.trim().toLowerCase();
