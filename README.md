<p align="center"><img src="docs/icon.png" width="128" alt="Headroom icon"></p>

# Headroom

**Your Mac's storage, in the notch.** Headroom shows how much space you have left right
around the camera notch, maps every GB on the disk, and gets space back in one click —
without losing anything you made.

Built for Macs that fill up from agentic coding: every repo an agent touches grows its own
`node_modules`, `.next`, `target` or virtualenv, and package caches, simulators and browser
engines pile up behind them.

![The notch, expanded](docs/screenshots/notch-expanded.png)

![Overview](docs/screenshots/overview.png)

![Every GB as a map](docs/screenshots/map.png)

## What it does

- **Notch** — a fill ring and the free space either side of the camera (Dynamic Island
  style). Hover it: gauge, the biggest safe wins, and **Reclaim**.
- **Overview** — free space, health, the disk split by area, and one button that reclaims
  only what is safe.
- **Map** — a treemap of every GB: squares sized by space, coloured by area. Safe-to-delete
  folders glow mint with hatching; review items get an amber dash. Click to drill in.
- **Reclaim** — everything reclaimable, grouped by safety, with what rebuilds each item
  (`pnpm install`, `cargo build`…).
- **Large files** — single big files anywhere in your folders, filtered by size and type.
  Pick several and move them to the Trash in one go (or delete permanently), with Undo.
- **Activity** — everything Headroom removed. Put Back anything still in the Trash, or delete
  it for good from here so the space actually comes back.
- **Apps** — every app with the data it keeps in your Library; uninstall moves the app
  *and* its leftovers to the Trash (recoverable until you empty it).
- **Watching** — a notification when space drops below your threshold or falls fast, with
  what Headroom can safely free.

## How "safe" is decided

| Verdict | Meaning | One click? |
|---|---|---|
| **Safe** | A cache or build output your tools recreate automatically | Yes |
| **Review** | Recreatable, but costly to rebuild or possibly in use (active projects, virtualenvs, simulators) | Opt-in |
| **Your data** | WhatsApp media, Downloads, backups, agent histories | Never — shown only |

- **Honest numbers.** Sizes are hard-link-aware: a pnpm `node_modules` is mostly links into
  the shared store, so Headroom shows what deleting it *actually* frees, not what it weighs.
- **Per-project staleness.** Build output of projects idle for 7+ days is safe; projects
  you touched recently always ask first.
- **One guarded deletion path.** `Cleaner` + `SafetyGuard` refuse anything marked as your
  data, protected folders (home, Desktop, Library…), credentials, iCloud Drive, photo
  libraries, symlink escapes, and anything outside the allowed roots.
- **Every GB accounted.** The map names the APFS volumes folders can't see — macOS,
  Preboot, swap, Recovery — and shows what's unreadable as such instead of hiding it.

## Build & run

Requires macOS 15+ and Xcode 16+ (Swift 6).

```bash
./scripts/bundle.sh          # → dist/Headroom.app (release, icon, ad-hoc signed), installed as /Applications/Headroom.app
open /Applications/Headroom.app
swift test                   # engine tests (each runs in a throwaway temp folder)
```

Read-only reports from the terminal (never deletes anything):

```bash
swift run headroom-cli status     # free space and health
swift run headroom-cli reclaim    # what one click would free (dry run)
swift run headroom-cli apps       # apps with their leftover data
swift run headroom-cli map        # every GB, by area
```

Design review without clicking through: `Headroom --render <dir>` scans for real and draws
every screen (and both notch states) to PNG.

## Layout

```
Sources/HeadroomCore/   engine — no UI, fully tested
  DiskWalker.swift      fts walker: physical, single-device, hard-link-aware
  Catalog.swift         known space hogs with safe/review/keep verdicts
  ProjectScanner.swift  build artifacts next to their markers, staleness per project
  Cleaner.swift         SafetyGuard + the only deletion path
  AppInventory.swift    apps + Library leftovers by bundle ID; uninstall to Trash
  DiskMap.swift         every GB by area, incl. APFS system volumes
  Treemap.swift         squarified treemap layout
Sources/Headroom/       the app: notch panel, menu bar, main window
Sources/headroom-cli/   read-only reports
```

## Keyboard

⌘1–⌘8 switch screens · ⌘R rescan · ⌘A select all · ⌘⌫ move selection to Trash ·
⌥⌘⌫ delete permanently · ⌘Z undo the last trash · Esc clear selection

## Contributing

Issues and pull requests are welcome. Before opening one:

- `swift test` passes, and `./scripts/bundle.sh --no-install` builds.
- Anything that removes files goes through `Cleaner` and `SafetyGuard` — never `FileManager`
  directly — and a new rule comes with a guard test. The full list of invariants is in
  [AGENTS.md](AGENTS.md).
- Screenshots for the README come from `Headroom --render <dir> --demo`, so no personal
  projects or files end up in the repo.

## License

[Apache License 2.0](LICENSE).

