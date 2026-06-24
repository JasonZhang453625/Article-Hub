# Article-Hub

Article-Hub is a local-first, AI-native personal knowledge inbox:

> **Share it into knowledge. Ask to find it again. Always trace it back to the source.**

The product is designed for people who save useful articles, videos, and posts across WeChat, Zhihu, Bilibili, Xiaohongshu, X, YouTube, and the wider web, but rarely find or reuse them later.

The target workflow is:

```text
Share a link
  → process it safely
  → create one clean AI summary knowledge card
  → tag and index it locally
  → ask questions across the whole library
  → open cited cards and original sources
```

Article-Hub remains local-first and BYOK. Content, metadata, and future vector indexes stay on the user's device. AI requests go directly to the model provider configured by the user; Article-Hub does not operate an AI content backend.

## Current Status

The current app is the foundation for the AI-native workflow. It already supports:

- **Local-first storage** with Hive and backward-compatible hand-written adapters
- **11 recognized sources**: WeChat, Zhihu, X, Bilibili, Xiaohongshu, ChatGPT, YouTube, Medium, Substack, Reddit, and generic web
- **Multiple capture paths**: manual URL entry, bulk URL entry, clipboard detection, and Android system sharing
- **Metadata and content processing**: title/cover extraction, article text extraction, and BYOK AI summaries
- **Knowledge-card reading**: a summary-first page with a direct path to the original page
- **Organization**: tags, notes, favorites, folders, nested folders, filters, and search
- **Built-in reader**: in-app WebView with a system-browser fallback
- **Portable data**: JSON backup and restore; API keys are excluded from exports

The following AI-native capabilities are **planned, not yet implemented**:

- A reliable processing inbox with visible failures and retries
- Automatic tags and folder suggestions
- BYOK embeddings and a rebuildable local summary index
- Whole-library RAG answers with cited knowledge cards
- A new primary navigation: Chat / Library / Processing / Settings

## Product Direction

The product is moving from a list-first bookmark manager with optional summaries to an AI-native knowledge workflow:

- A shared link must be saved before any network or AI work begins.
- One article becomes one normalized AI summary knowledge card and one retrieval chunk.
- The home screen becomes a conversation with the entire local knowledge library.
- Every generated answer must cite real saved cards.
- If the saved summaries do not contain enough information, the app must say so instead of inventing an answer.
- Original pages remain available for verification and deeper reading.

See [`docs/OVERVIEW.md`](docs/OVERVIEW.md) for the product overview, [`docs/PRD.md`](docs/PRD.md) for product requirements, and [`docs/ROADMAP.md`](docs/ROADMAP.md) for the phased implementation plan.

## Getting Started

Requires Flutter with Dart 3.11+.

```bash
flutter pub get
flutter run
```

Run checks:

```bash
flutter analyze
flutter test
```

## Architecture

| Concern | Choice |
|---|---|
| Framework | Flutter |
| State management | Riverpod |
| Local storage | Hive with hand-written `TypeAdapter`s |
| Routing | go_router |
| Built-in reader | flutter_inappwebview |
| AI integration | User-configured OpenAI-compatible API |
| Backend | None |

```text
lib/
├── config/        # Theme and routing
├── data/          # Models, repositories, and processing services
├── features/      # Feature-first screens
└── shared/        # Shared providers, utilities, and widgets
```

## Privacy

- Core data stays on the device.
- Article-Hub does not operate a content or AI proxy backend.
- AI content is sent only to services explicitly configured by the user.
- API keys are stored locally and excluded from JSON backups.
- Planned embeddings and vector indexes are local derived data and will also be excluded from backups.
