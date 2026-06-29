// ═══ Barrel re-exports ═══════════════════════════════════════════════
// This file exists for backward compatibility. All provider code has been
// split into domain-specific files:
//   article_providers.dart  — ArticlesNotifier, Hive init, search/filter state
//   folder_providers.dart   — FoldersNotifier
//   display_providers.dart  — filteredArticles, knowledgeBase, pending articles
//   ai_providers.dart       — embedding, index, retrieval services
//
// New code should import from the specific files above directly.
// ════════════════════════════════════════════════════════════════════════

export 'article_providers.dart';
export 'folder_providers.dart';
export 'display_providers.dart';
export 'ai_providers.dart';
