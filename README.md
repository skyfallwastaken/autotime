# Autotime

A free, native SwiftUI alternative to [Timing](https://timingapp.com) for macOS. Autotime tracks which app is in front and uses the Accessibility API to break activity down into browser URLs, document and folder paths, and Slack/Discord/Teams workspaces and channels. Everything stays local in SQLite.

## Install

1. Download `Autotime-<version>.dmg` from the [latest release](https://github.com/skyfallwastaken/autotime/releases/latest) and drag Autotime into Applications.
2. Open Autotime. The release is signed with Autotime's own certificate, not an Apple Developer ID, so the first launch is blocked: open **System Settings → Privacy & Security** and click **Open Anyway**.
3. Grant Accessibility access when asked.

After that, Autotime keeps itself up to date with [Sparkle](https://sparkle-project.org) (**Autotime → Check for Updates…**, or automatically once a day). Updates are signed with the same certificate, so Accessibility access survives them. Apple silicon only.

## Release

Push a version tag, or run the **Release** workflow from the Actions tab with a version:

```sh
git tag v1.2.0 && git push origin v1.2.0
```

`.github/workflows/release.yml` builds and signs the app, packages the DMG (`scripts/make-dmg.sh`), signs it for Sparkle, and publishes a GitHub Release with the DMG and `appcast.xml`. The app's feed is `releases/latest/download/appcast.xml`, so it always sees the newest release. Sparkle can only fetch it while the repository is public.

Repository secrets:

| Secret | Purpose |
| --- | --- |
| `SIGNING_CERTIFICATE_P12`, `SIGNING_CERTIFICATE_PASSWORD` | Base64 `.p12` of the code signing identity. Replacing it with a Developer ID changes the app's signature, so existing installs lose Accessibility access once and must allow the new build. |
| `SPARKLE_PRIVATE_KEY` | EdDSA key for update signatures; its public half is `SUPublicEDKey` in `Resources/Info.plist`. Losing it means existing installs can't verify updates. |

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
- System helper processes (notification and permission prompts, Dock, loginwindow, etc.; see `Store.hiddenBundleIDs`) are never tracked and are hidden from imported or older data
- Import from Timing (`~/Library/Application Support/info.eurocomp.Timing2/SQLite.db`) and from Screen Time (Biome `App.InFocus` + `knowledgeC.db`)

## Layout

| File | Purpose |
| --- | --- |
| `Tracker.swift` | 1s sampling loop, idle/lock/sleep handling, video detection via power assertions |
| `Extractor.swift` | Per-app title/path extraction (Slack, Discord, Teams, Mail, Notes, Messages and other Catalyst apps, GitHub Desktop, browsers incl. Firefox via its session file, editors) |
| `Accessibility.swift` | Thin AXUIElement wrapper |
| `Store.swift` | SQLite storage and Timing import |
| `ScreenTimeImporter.swift` | SEGB/Biome and knowledgeC parsing |
| `Model.swift` | Path components, tree building, sessions, timeline blocks |
| `Updater.swift` | Sparkle updater and Check for Updates command |
| `*View.swift` | SwiftUI UI |
| `scripts/make-dmg.sh` | DMG packaging (dmgbuild settings and background in `scripts/`) |

Data lives in `~/Library/Application Support/Autotime/autotime.sqlite`.
