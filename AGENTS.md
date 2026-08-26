# 记忆海 — Agent Instructions

## Project overview

Memora（记忆海）is a multi-part product, not only a Flutter app. The user-facing client is local-first, while optional account, sync, Hosted AI/Agent, administration, landing, and release capabilities are provided by separate components:

1. **Flutter client (this repository)** — captures and organizes content from 11+ platforms, stores the primary knowledge library in Hive, runs the metadata → content → summary → tags → folder pipeline, and provides local retrieval/RAG plus BYOK and Hosted Agent chat paths.
2. **Landing page (`landing-page/`)** — a separate Astro repository/worktree for `https://memora.wang`. It is represented by a gitlink in this repository, but there is currently no `.gitmodules`; do not assume normal submodule commands will work. Release CI checks out `JasonZhang453625/Memora-Landing-Page` explicitly.
3. **Backend (production `/opt/memora-backend`)** — an independent TypeScript/Fastify repository deployed with Compose. It owns email OTP authentication, devices/sessions, sync protocol v3, PostgreSQL/Prisma, Hosted AI and durable Agent runs, web/image services, quota/subscriptions/feedback, and the `/admin` dashboard. It is not stored as tracked source in this Flutter repository.
4. **Delivery infrastructure** — GitHub Actions builds/tests/signs the Android APK, publishes GitHub Release assets and the China download source under `api.memora.wang/downloads`, and deploys the landing page.

The local `scratchpad/pi-backend-edit/` directory may be an independent backend working copy with its own Git state and concurrent edits. It is not the production source of truth and must never be copied or reset wholesale without first comparing it with `/opt/memora-backend`.

### Evidence boundaries

Always report these as separate evidence levels:

- **Code evidence**: source inspection, focused tests, `flutter analyze`, backend lint/build/tests.
- **Deployment/reachability**: Compose status, public `/health`, release manifest/download checks.
- **Acceptance**: a real authenticated account, rebuilt app/device flow, process-death recovery, or two-device sync/conflict behavior as applicable.

Passing one level does not prove the next. In particular, `/health` 200 does not prove Hosted Agent, Admin, APK distribution, or two-device synchronization.

## Key commands

```bash
flutter pub get              # Install dependencies
flutter run                  # Run on connected device/emulator
flutter run -d edge          # Run in Edge browser
flutter analyze              # Static analysis (uses flutter_lints)
flutter test                 # Run all tests
flutter test test/foo_test.dart  # Run single test file
flutter build apk --debug    # Local Android smoke build
```

Production App release in the configured Codex workspace uses the local `build-pipeline` skill and its one-command orchestrator:

```powershell
dart run tools/release_pipeline.dart "type(scope): description"
```

`tools/release_pipeline.dart` and `.agents/skills/build-pipeline/` are machine-local/ignored in the current checkout. For a clean clone, inspect the tracked `tools/release.dart`, `tools/verify_release.dart`, `.github/workflows/release.yml`, and release docs instead of assuming the local wrapper exists. Do not hand-build a production APK when the CI release path is requested; CI owns the full test suite, signed release build, GitHub Release, server activation, and landing deployment.

Landing development is run inside its own worktree:

```powershell
cd landing-page
npm install
npm run dev
npm run build
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
- **Backend base URL**: `lib/config/backend_config.dart`; defaults to `https://api.memora.wang` and can be overridden with `--dart-define=MEMORA_API_BASE_URL=...`.
- **AI paths**: BYOK calls a user-selected OpenAI-compatible provider directly; Hosted mode authenticates against the Memora backend and uses durable `/ai/runs` + SSE recovery. Model capability declarations outrank name heuristics.
- **Sync**: local mutations enter a persistent outbox; sync protocol v3 uses server revisions and client shadows for conflict handling. Account sync is optional and is not end-to-end encrypted.

```
lib/
├── main.dart            # Entry point — ProviderScope wraps App
├── app.dart             # MaterialApp.router with theme/locale setup
├── config/
│   ├── routes.dart      # GoRouter config, all route paths defined here
│   └── theme.dart       # Light/dark ThemeData
├── data/
│   ├── models/          # Article, settings, folders, chat/attachment models
│   ├── repositories/    # Article and chat Hive persistence
│   └── services/        # Extraction, AI/Agent, RAG, auth/sync, backup, updates
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
    ├── providers/       # article/chat/auth/sync/settings/filter providers
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
- `auth_service.dart` / `sync_*` — account sessions, outbox, v3 sync, shadows, apply/conflict handling
- `hosted_ai_service.dart` / `hosted_agent_service.dart` / `hosted_task_run_*` — backend-hosted and durable Agent execution
- `agent_client_tool_*` — server-coordinated client-tool claims, receipts, execution, and crash recovery
- `chat_attachment_*` / `image_understanding_service.dart` — file/image inputs and multimodal fallback
- `app_update_service.dart` — Android update manifest and dual-source APK selection

## Product component map and sources of truth

| Component | Source of truth | Runtime / public surface | Normal validation |
|---|---|---|---|
| Flutter App | This repository: `lib/`, `test/`, platform folders | Android primary; other Flutter platforms have narrower support | focused tests → `flutter analyze` → debug/device acceptance |
| Landing | Separate Git repo in `landing-page/`, branch `master` | `https://memora.wang` | `npm run build`, then browser/console check when changed |
| Backend API | Independent Git repo at production `/opt/memora-backend` | `https://api.memora.wang`; API docs `/docs` | backend lint/build/tests, Compose status, public health, feature-specific API acceptance |
| Database | Backend `prisma/schema.prisma` + `prisma/migrations/` | PostgreSQL Compose service | migration review, backup, `prisma migrate deploy`, API/data isolation checks |
| Hosted Agent | Backend `src/agent/`, `config/agent.toml`, `skills/`, `src/routes/aiRuns.ts` | authenticated `/ai/*` and `/ai/runs`/SSE | backend tests + real logged-in run/reconnect/cancel acceptance |
| Admin | Backend `src/routes/admin*.ts` | `/admin` and token-protected `/admin/*` APIs | admin route tests + authenticated browser check; never expose the admin token |
| APK delivery | `.github/workflows/release.yml`, `deploy/`, tracked release tools | GitHub Release + `api.memora.wang/downloads/android/*` | `tools/verify_release.dart` contract checks |

The client/backend contract is represented in client services and tests plus `docs/SERVER_AUTH_SYNC_AGENT_PROMPT.md` and `docs/MEMORA_PI_CLIENT_TOOLS.md`. Those handoff docs can lag production; verify the current client request path and production backend source before changing either side.

## Backend access and iteration

Remote access routing is intentionally machine-local:

1. Read `.codex/access.local.md` before any server operation. It is ignored by Git and must remain local-only.
2. Use the listed SSH target and identity with Windows OpenSSH, key authentication, `BatchMode=yes` for probes, and strict host-key checking. A safe template is:

   ```powershell
   ssh -i <identity-from-access.local.md> -o BatchMode=yes -o StrictHostKeyChecking=yes <target-from-access.local.md>
   ```

3. After connecting, the backend repository is `/opt/memora-backend`. Start read-only:

   ```bash
   cd /opt/memora-backend
   git status --short
   git log -1 --oneline
   docker compose ps
   curl -fsS https://api.memora.wang/health
   ```

4. Before editing, inspect the remote `README.md`, `package.json`, `scripts/deploy.sh`, current Git status, migrations, and Compose configuration. Preserve `.env`, certificates, backups, database volumes, server-only configuration, `.bak*` files, and concurrent edits.
5. Develop backend changes in an isolated working copy when practical. If using `scratchpad/pi-backend-edit/`, treat it as a separate dirty repository: run `git status`, compare its HEAD and diff with production, and copy only intended files. Never assume it is current merely because it has an SSH remote.
6. Validate in proportion to the change: focused Vitest files, then `npm run build` and relevant lint/full tests. A database change requires a new Prisma migration and a verified backup/rollback plan; never edit production tables manually as a substitute for a migration.
7. Deploy only when the user has asked for deployment. Read the current remote deploy script first; then rebuild the affected service, confirm Compose state and public health, and run feature-specific authenticated acceptance. Preserve the distinction between deployed code and real device/two-device proof.

Never put server passwords, private keys, tokens, `.env` values, connection strings, or complete credential-bearing commands into tracked docs, terminal logs, chat, screenshots, or memory.

## Landing and cross-component changes

- Run Git commands for Landing inside `landing-page/`; it has its own branch, remote, lockfile, workflow, and history.
- A main-repository `git status` may show `M landing-page` only because the gitlink moved. Do not stage that drift unless the intended task explicitly updates the pointer.
- When an API contract changes, update backend implementation/tests, Flutter service/models/tests, and relevant docs together. Deploy backend compatibility before releasing a client that depends on it.
- When a release or download contract changes, inspect `.github/workflows/release.yml`, `deploy/memora-publish-apk`, `tools/verify_release.dart`, `docs/APK_DISTRIBUTION_SERVER.md`, and Landing download rendering as one chain.

## Git rules

- **Don't touch unrelated changes.** Unstaged/untracked files that are NOT part of the current task were likely modified in another session — leave them alone. Only stage and commit files relevant to the current request.
- Check `git status --short` before and after work. Nested `landing-page/` and `scratchpad/pi-backend-edit/` have independent Git state; inspect them separately when in scope.
- Do not run `git add -A`, destructive reset/checkout, or bulk-copy a backend tree across repositories. Stage exact intended paths and report preserved concurrent work.

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
- **Processing pipeline is single-pass and resumable**. Each stage writes `processingStatus` + `processingStage` to Hive so a crash never loses progress. Extracted page content is held in a transient in-memory `_contentCache` keyed by article id — **never** persisted into the user-facing `notes` field. Protocol-v4 Hosted folder tasks write `suggestedFolderId` for user confirmation; the legacy BYOK path still directly assigns or creates a folder. Preserve this path-specific behavior unless the product contract is intentionally changed.
- **No `build_runner` or codegen** in this project. Everything is manual.
- **Version/release contract**: Production releases use the configured release pipeline. Its driver bumps the patch version and maps Android build number as `MAJOR * 10000 + MINOR * 100 + PATCH` (for example `2.1.8+20108`); `MINOR` and `PATCH` must remain within `0..99`. Never delete, move, or reuse a published tag—fix forward with a new patch.

## Testing

Flutter tests live in `test/` (currently a broad suite rather than the short historical list below). Representative areas include:

- `backup_test.dart`, `url_helpers_test.dart`, `source_platform_test.dart`, `date_formatter_test.dart`, `widget_test.dart`
- `chat_screen_widget_test.dart`, `embedding_retrieval_test.dart`, `index_consistency_test.dart`, `processing_state_test.dart`, `rag_citation_test.dart`, `retrieval_log_test.dart`, `retrieval_query_set_test.dart`, `security_test.dart`
- auth/sync/conflict, Hosted AI/Agent recovery, client tools, attachments/image understanding, processing queue/pipeline, update, reader, and settings serialization tests

Run a single test with `flutter test test/<name>.dart`.

Do not repeat stale test-count or known-gap claims from older docs without checking the current tree. Backend tests live in the independent backend repository under `test/`; Landing uses its own build/workflow. Run focused checks while iterating and let release CI run the authoritative full Flutter suite and signed APK build.

## Docs

- `docs/OVERVIEW.md` — full product overview
- `docs/PRD.md` — product requirements
- `docs/ROADMAP.md` — phased development plan (Chinese)
- `docs/SERVER_AUTH_SYNC_AGENT_PROMPT.md` — client/backend auth and sync handoff contract (verify against current code)
- `docs/MEMORA_PI_CLIENT_TOOLS.md` — durable Agent client-tool contract
- `docs/APK_DISTRIBUTION_SERVER.md` — China APK download contract
- `docs/RELEASE_AUTOMATION_SETUP.md` — release environment setup; treat concrete host values as operational configuration and do not copy secrets into chat
- `.agents/skills/build-pipeline/SKILL.md` — machine-local production App release procedure in this workspace
