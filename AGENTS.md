# Headroom — agent notes

macOS-only notch app (Swift 6 / SwiftUI, macOS 15+): shows where every GB of the disk goes
and reclaims space safely. Lives at `/Applications/Headroom` — this folder is both the git
repo (github.com/everyai-com/headroom, private) and the installed app.

## Commands

- build + install: `./scripts/bundle.sh` → `dist/Headroom.app`, copied to `./Headroom.app`
  (+ `./headroom-cli`); `--no-install` to skip the copy. Then `open Headroom.app`.
- tests: `swift test` (engine only; every test runs in a throwaway temp folder)
- read-only reports: `./headroom-cli status|reclaim|projects|apps|map|files|growth|activity` (`--json`)
- distribution signing: `HEADROOM_SIGN_ID="Developer ID Application: …" HEADROOM_NOTARY_PROFILE=<profile> ./scripts/bundle.sh`
- design review: `.build/release/Headroom --render <dir>` draws every screen + both notch
  states to PNG from real scans (ImageRenderer can't draw ScrollView — views use
  `Scrolling {}`, which lays out flat in snapshot mode)
- demo video: `./scripts/make-reel.sh` → `dist/Headroom-demo.mp4` (`Headroom --reel <dir> --demo`
  renders captioned frames from the real flow on seeded demo data; see docs/DEMO.md)
- app icon: `Headroom --icon <png>` (bundle.sh slices it into the .icns)

## Layout

- `Sources/HeadroomCore` — engine, no UI: `DiskWalker` (fts, hard-link-aware), `Catalog`
  (known space hogs + verdicts), `ProjectScanner` (build artifacts, per-project staleness),
  `Cleaner`/`SafetyGuard`, `AppInventory` (apps + Library leftovers), `DiskMap` (every GB,
  APFS volumes), `Treemap` (squarified layout)
- `Sources/Headroom` — app: `Notch.swift` (NSPanel over the camera housing), `MainView`
  (sidebar), `OverviewView`, `MapView` (treemap), `ReclaimView`, `AppsView` (+ Settings),
  `AppModel` (state + actions), `Theme` (design system), `main.swift` (delegate, menu bar,
  monitor, notifications)
- `Sources/headroom-cli` — read-only reports

## Invariants (do not break)

- `Cleaner` is the ONLY code that deletes, and every path goes through `SafetyGuard.check`:
  never `.keep` findings or `.none` methods, never protected folders (home, Desktop,
  Library, Caches itself…), credentials (~/.ssh, Keychains), iCloud Drive, Mail/Messages,
  photo libraries, symlink escapes, or anything outside home +
  `/Library/Developer/CoreSimulator/Caches`. Project artifacts must still be a recognised
  artifact folder name. Add a guard test for any new rule.
- One click reclaims `.safe` only. Safe = regenerable cache/build output. Build output of a
  project touched within `staleDays` is `.review`, never one-click. Virtualenvs and Pods are
  always `.review`. One click re-checks project activity first (`ProjectScanner.revalidated`):
  a project touched since the scan drops back to `.review`.
- Sizes are hard-link-aware (`reclaimable` ≤ `allocated`): show what deleting frees, not what
  a folder weighs — pnpm `node_modules` are mostly links into the store.
- App uninstall moves to the Trash (recoverable); Apple apps and running apps are refused.
  Leftovers match by exact bundle ID (+ exact app name only in Application Support/Logs);
  in Group Containers the ID must appear as whole dot-separated parts (never NotesPro for Notes).
- `SafetyGuard` compares paths case-folded — the startup disk is case-insensitive.
- Map actions (Trash / Empty / Delete / Reclaim on any square) build a `Finding.picked` and go
  through `Cleaner` like everything else — never `FileManager` directly. Every destructive one
  confirms first; `.keep` folders, anything inside a real `.app` bundle and any
  `.photoslibrary` are refused (apps are uninstalled whole, via `AppInventory`).
- The guard also refuses git history (`.git` and inside) and live VM disks (`~/.colima`,
  `~/.lima`, `~/.orbstack`…) — except for a `.command` finding (the tool's own prune). Only
  `xcrun simctl` may reach `/Library/Developer/CoreSimulator`. A finding with no paths never runs.
- Never-touch list (`SafetyGuard.excluded`, UserDefaults `neverTouch`): refused at, inside or
  containing an excluded path; `Exclusions.apply` hides them from scans.
- Every removal is logged to `ActivityLog` (Application Support/Headroom/activity.json) with
  where trashed items landed; Put Back never overwrites. Auto-reclaim (off by default) is the
  safe set only, at most every 6 h.
- Large files come from the map walk (`BigFileCollector`): home only, never Library, `.git`,
  VM homes, apps or photo libraries.
- System size comes from `diskutil` (`CapacityInUse`), never `statfs("/")` — on APFS that
  reports the whole container. The map names APFS volumes (macOS, Preboot, swap, Recovery)
  and shows unreadable space as "Other", never hides it.
- `Category` clashes with an ObjC runtime type — the enum is `StorageCategory`.
- Spotlight's index can be read-only: app last-used falls back to the newest change in the
  app's own data (`lastUsedIsExact = false`) and says "usage unknown", never "never opened".
- Notch geometry: `NSScreen.auxiliaryTopLeftArea/RightArea` + `safeAreaInsets.top`; panel at
  `.statusBar + 1`, all spaces, full-screen auxiliary. Non-notch screens get a centred pill.
