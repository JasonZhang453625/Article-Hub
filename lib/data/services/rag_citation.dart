/// Pure helpers for the RAG conversation flow: building the candidate context
/// and extracting/validating article citations from a model response.
///
/// Kept free of Flutter and Riverpod so the citation logic — the part that
/// guards against the model citing articles that were never offered or no
/// longer exist — can be unit-tested directly.
library;

/// Maps the 1-based citation numbers shown to the model back to article IDs.
/// [candidateIds] is the ordered list of candidate article IDs (index 0 → "[1]").
Map<String, String> buildCitationMap(List<String> candidateIds) {
  final map = <String, String>{};
  for (int i = 0; i < candidateIds.length; i++) {
    map['${i + 1}'] = candidateIds[i];
  }
  return map;
}

/// Extracts the article IDs the model cited via `[n]` markers in [response].
///
/// Only citation numbers that appear in [citationMap] are resolved, and the
/// result is further filtered against [validIds] (the IDs of articles that
/// currently exist) so a hallucinated or deleted reference can never leak
/// through. Returns the cited IDs in candidate order, de-duplicated.
List<String> extractValidCitations({
  required String response,
  required Map<String, String> citationMap,
  required Set<String> validIds,
}) {
  final cited = <String>[];
  for (final entry in citationMap.entries) {
    if (response.contains('[${entry.key}]')) {
      final id = entry.value;
      if (validIds.contains(id) && !cited.contains(id)) {
        cited.add(id);
      }
    }
  }
  return cited;
}
