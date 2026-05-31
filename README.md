# Article-Hub

Article-Hub is a cross-platform Flutter app for collecting, organizing, and revisiting articles, videos, and posts from the platforms you actually use — X, Bilibili, Xiaohongshu (Rednote), WeChat, Zhihu, ChatGPT, YouTube, Medium, Substack, Reddit, and the wider web.

Paste a link and it's saved. The app detects the source platform automatically, lets you tag and annotate it, and keeps everything searchable in one place — so the things you meant to read later are actually findable later.

## Why

Great content is scattered across a dozen apps that don't talk to each other. Your WeChat favorites, Bilibili watch-later, X bookmarks, and browser tabs all live in separate silos with no tags, no notes, and no unified search. Article-Hub turns that fragmented collection into a single, searchable personal library that you own.

## Features

- **One-step save** — paste any URL; the source platform is detected automatically from its domain
- **11 recognized sources** — WeChat, Zhihu, X, Bilibili, Xiaohongshu, ChatGPT, YouTube, Medium, Substack, Reddit, plus generic web, each with its own icon and accent color
- **Organize** — free-form tags, notes, favorites, and automatic timestamps
- **Search & filter** — full-text search across titles, tags, notes, and URLs; filter by source; build reusable custom filter groups (tag keywords + source platforms)
- **Built-in reader** — open saved links in an in-app WebView with zoom, progress, and smart deep-link handling, with a one-tap fallback to the system browser
- **Backup & restore** — export all your data (articles, filters, settings) to a JSON file and import it back; your data is never locked in
- **Personalization** — light / dark / system themes, adjustable global font size, configurable reader zoom, and reorderable / hideable source chips
- **Local-first & private** — data is stored on-device with Hive; nothing is uploaded or tracked

## Getting started

Requires the Flutter SDK (Dart 3.11+).

```bash
flutter pub get
flutter run
```

Run the analyzer and tests:

```bash
flutter analyze
flutter test
```

## Project structure

```
lib/
├── config/        # Theme and routing
├── data/
│   ├── models/        # Article, SourcePlatform, AppSettings, FilterGroup
│   ├── repositories/  # Hive-backed persistence
│   └── services/      # Backup export/import
├── features/      # Feature-first screens
│   ├── home/          # List, search, and filtering
│   ├── add_passage/   # Add an article
│   ├── detail/        # Edit details
│   ├── reader/        # In-app reader
│   └── settings/      # Settings and backup
└── shared/        # Cross-feature providers, utils, and widgets
```

## Tech stack

| Concern | Choice |
|---------|--------|
| Framework | Flutter (Dart 3.11) |
| State management | Riverpod |
| Local storage | Hive (hand-written `TypeAdapter`s for backward-compatible schemas) |
| Routing | go_router with custom transitions |
| In-app reader | flutter_inappwebview |

## Roadmap

Article-Hub is evolving from a local collection tool into a cross-device, AI-assisted reading hub — AI summaries that let you read the gist without opening the original page, multi-device cloud sync, and richer organization and import.

See [`docs/OVERVIEW.md`](docs/OVERVIEW.md) for a full product overview, [`docs/PRD.md`](docs/PRD.md) for requirements, and [`docs/ROADMAP.md`](docs/ROADMAP.md) for the phased plan.
