# 记忆海 — Agent Instructions

## Project overview

Cross-platform Flutter app for saving and organizing articles from 11+ platforms (WeChat, Bilibili, X, Xiaohongshu, YouTube, etc.). Local-first with Hive storage, no backend. Includes an AI-driven processing pipeline (metadata → content → summary → tags → folder suggestion) and a local RAG (embedding + retrieval) layer over saved articles.

## Key commands

```bash
flutter pub get              # Install dependencies
flutter run                  # Run on connected device/emulator
flutter run -d edge          # Run in Edge browser
flutter analyze              # Static analysis (uses flutter_lints)
flutter test                 # Run all tests
flutter test test/foo_test.dart  # Run single test file
flutter build apk --release  # Build Android APK (run bump_version first)
dart run tools/bump_version.dart  # Auto-increment patch version in pubspec.yaml
```

## Architecture

- **State management**: Riverpod (`flutter_riverpod`). Screens are `ConsumerWidget` / `ConsumerStatefulWidget`.
- **Storage**: Hive with hand-written `TypeAdapter`s (no codegen). Type IDs are hardcoded and MUST stay stable:
  - `Article` = 0  (box: `'passages'` — legacy name kept for backward compat)
  - `SourcePlatform` = 1  (stable-int storage, see below)
  - `AppSettings` = 2
  - `FilterGroup` = 3
  - `Folder` = 4
  - `IndexRecord` = 6  (vector index entries; box: `'index_records'`)
- **Routing**: `go_router` with custom fade+slide transitions in `lib/config/routes.dart`.
- **Pattern**: Feature-first structure under `lib/features/`.

```
lib/
├── main.dart            # Entry point — ProviderScope wraps App
├── app.dart             # MaterialApp.router with theme/locale setup
├── config/
│   ├── routes.dart      # GoRouter config, all route paths defined here
│   └── theme.dart       # Light/dark ThemeData
├── data/
│   ├── models/          # Article, SourcePlatform, AppSettings,
│   │                    # FilterGroup, Folder
│   ├── repositories/    # ArticleRepository (Hive CRUD)
│   └── services/        # See "Services" below
├── features/
│   ├── home/            # List + search + filter UI
│   ├── add_passage/     # Add article form
│   ├── detail/          # Edit article details
│   ├── reader/          # In-app WebView reader
│   ├── inbox/           # Pending/processing/failed items + retry
│   ├── chat/            # RAG chat UI over the local knowledge base
│   ├── folders/         # Folder management (create/rename/reparent)
│   ├── settings/        # Settings + backup screen
│   └── shell/           # App shell (bottom nav, tab scaffolding)
└── shared/
    ├── providers/       # passage_providers, filter_providers,
    │                    # settings_providers
    ├── utils/           # DateFormatter, UrlHelpers
    └── widgets/         # DelayedReveal
```

### Services (`lib/data/services/`)

- `metadata_service.dart`   — Open Graph / `<title>` scraping for cards
- `content_extractor.dart`  — Page body extraction for AI input
- `ai_service.dart`         — OpenAI-compatible chat/summary client
- `embedding_service.dart`  — OpenAI-compatible embeddings client
- `index_service.dart`      — Local vector store (`IndexRecord` Hive box)
- `retrieval_service.dart`  — Cosine-similarity search over the index
- `retrieval_log_service.dart` — Persists retrieval queries for debugging/eval
- `rag_citation.dart`       — Citation parsing/validation for RAG answers
- `processing_pipeline.dart` — Orchestrates the 5-stage knowledge pipeline
- `backup_service.dart`     — JSON export/import (uses `backup_data.dart`)

## Git rules

- **Don't touch unrelated changes.** Unstaged/untracked files that are NOT part of the current task were likely modified in another session — leave them alone. Only stage and commit files relevant to the current request.

## Credential access

- Never store access tokens, passwords, private keys, or complete credential-bearing commands in this repository, `AGENTS.md`, Codex memory, logs, or chat.
- For GitHub API, issue, pull-request, workflow, and repository-status operations, prefer the authenticated Codex GitHub connector. Local Git remotes use SSH.
- When remote-server access is required, read the machine-local instructions in `.codex/access.local.md`. That file is intentionally ignored by Git and must remain local-only.
- Prefer SSH public-key authentication. Never place a server password on a command line; do not weaken host-key checking.
- If a credential has appeared in chat or another plaintext channel, treat it as exposed: rotate/revoke it instead of persisting it.
- Tavily MCP and CLI authentication must use OAuth. Never put a Tavily API key in an MCP URL, config file, environment dump, or `tvly login --api-key` command.
- Tavily skills must not auto-run `curl | bash` installers; the CLI is already installed. Treat `tavily-dynamic-search` Python/`uv run` execution as approval-required.

## Critical conventions

- **Hive adapters are hand-written**, not generated. When adding a field to a model, update the `TypeAdapter` manually — both `read()` and `write()` — and bump the field count in `writeByte()`. New fields MUST use null-aware reads (`fields[N] as Type?`) for backward compatibility with data written by older builds.
- **SourcePlatform enum uses stable integer storage** via `SourcePlatformAdapter.toStoredValue()` / `fromStoredValue()`. Never rely on `.index` — the mapping is explicit so reordering enum cases doesn't corrupt existing data.
- **Route params**: `reader` and `detail` accept an `Article` via `state.extra` (not URL params). The `ArticleResolver` widget handles both the direct-object path and the id-based lookup fallback.
- **Article model name**: The class is `Article` (not `Passage`), but the Hive box name is still `'passages'` for backward compatibility. The constant lives at `ArticleRepository.boxName`; **do not** open `'passages'` directly elsewhere — go through the repository.
- **Article.copyWith uses sentinel values** (`Article.clearValue`) to distinguish "leave field unchanged" from "clear the field". Pass `Article.clearValue` to explicitly null out a nullable field.
- **Processing pipeline is single-pass and resumable**. Each stage writes `processingStatus` + `processingStage` to Hive so a crash never loses progress. Extracted page content is held in a transient in-memory `_contentCache` keyed by article id — **never** persisted into the user-facing `notes` field. AI-suggested folders write to `suggestedFolderId`; the user must confirm before the article actually moves.
- **No `build_runner` or codegen** in this project. Everything is manual.
- **Version bump before release builds**: Run `dart run tools/bump_version.dart` before `flutter build apk --release` (or any release build), unless `pubspec.yaml` already contains the intentional unpublished version for the iteration. The tool increments the patch version and maps the Android build number as `MAJOR * 10000 + MINOR * 100 + PATCH` (for example `2.1.8+20108`). `MINOR` and `PATCH` must remain within `0..99`.

## Testing

Tests live in `test/`. Current files:

- `backup_test.dart`, `url_helpers_test.dart`, `source_platform_test.dart`, `date_formatter_test.dart`, `widget_test.dart`
- `chat_screen_widget_test.dart`, `embedding_retrieval_test.dart`, `index_consistency_test.dart`, `processing_state_test.dart`, `rag_citation_test.dart`, `retrieval_log_test.dart`, `retrieval_query_set_test.dart`, `security_test.dart`

Run a single test with `flutter test test/<name>.dart`.

Known gaps (see `docs/ROADMAP.md` §1.4): per-stage success/failure tests for `ProcessingPipeline`, widget tests for the inbox empty/processing/failed states, and `MetadataService.parseHtmlMetadata` unit coverage.

## Docs

- `docs/OVERVIEW.md` — full product overview
- `docs/PRD.md` — product requirements
- `docs/ROADMAP.md` — phased development plan (Chinese)

## LangChain documentation

When implementing or reviewing LangChain, Dart LangChain, agent workflows, tool calling, or RAG orchestration, consult these official sources before relying on prior knowledge:

- Dart LangChain package: <https://pub.dev/packages/langchain>
- Dart LangChain API reference: <https://pub.dev/documentation/langchain/latest/>
- LangChain Docs MCP: `langchain-docs` (`https://docs.langchain.com/mcp`)
