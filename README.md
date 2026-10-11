# Autotime

A free, native SwiftUI alternative to [Timing](https://timingapp.com) for macOS. Autotime tracks which app is in front and uses the Accessibility API to break activity down into browser URLs, document and folder paths, and Slack/Discord/Teams workspaces and channels. Everything stays local in SQLite.

## Build

Requires macOS 14+ and Swift 6 (Command Line Tools are enough).

```sh
./build.sh
open build/Autotime.app
```

`build.sh` builds a release binary, wraps it in `build/Autotime.app`, generates the icon, and signs it with the first Apple Development / Developer ID identity in your keychain (ad-hoc if none). Set `CODESIGN_IDENTITY` to override. A stable signing identity keeps the Accessibility permission across rebuilds.

On newer SDKs `@State` is a macro whose plugin only ships with Xcode, so `build.sh` loads `libSwiftUIMacros.dylib` from `/Applications/Xcode.app` when it exists.

## Permissions

- **Accessibility** (required for titles, URLs, paths, channels). Prompted on first launch.
- **Full Disk Access** (optional) for importing Screen Time history.

## Features

- Activities outline (Unified / By Category / Chronological), per-app sidebar filter, search
- Day timeline with app strip and activity blocks; drag to select a time range
- Stats: by hour/day, app share, top websites, folders and documents, conversations, categories
- Menu bar extra with today's total and pause toggle
- Idle detection that keeps counting while the frontmost app plays video
- Import from Timing (`~/Library/Application Support/info.eurocomp.Timing2/SQLite.db`) and from Screen Time (Biome `App.InFocus` + `knowledgeC.db`)

## Layout

| File | Purpose |
| --- | --- |
| `Tracker.swift` | 1s sampling loop, idle/lock/sleep handling, video detection via power assertions |
| `Extractor.swift` | Per-app title/path extraction (Slack, Discord, Teams, Mail, browsers, editors) |
| `Accessibility.swift` | Thin AXUIElement wrapper |
| `Store.swift` | SQLite storage and Timing import |
| `ScreenTimeImporter.swift` | SEGB/Biome and knowledgeC parsing |
| `Model.swift` | Path components, tree building, sessions, timeline blocks |
| `*View.swift` | SwiftUI UI |

Data lives in `~/Library/Application Support/Autotime/autotime.sqlite`.
