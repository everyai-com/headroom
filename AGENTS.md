# Headroom — agent notes

macOS-only notch app (Swift 6 / SwiftUI, macOS 15+): shows where every GB of the disk goes
and reclaims space safely — and a Finder alternative for your own files: shelves by kind with big
thumbnails, plain-English search, text in images, where downloads came from, duplicates and clean-up cards. The git repo (github.com/everyai-com/headroom, public, Apache-2.0)
lives at `/Applications/Headroom`; the built app installs as `/Applications/Headroom.app`.
README screenshots are rendered with `--demo` so no personal projects or files are published.

## Commands

- build + install: `./scripts/bundle.sh` → `dist/Headroom.app`, installed as `/Applications/Headroom.app`
  (+ `./headroom-cli`); `--no-install` to skip the copy. Then `open /Applications/Headroom.app` — opening
  it by hand shows the window; a login-item launch stays in the notch and menu bar.
- tests: `swift test` (engine only; every test runs in a throwaway temp folder)
- read-only reports: `./headroom-cli status|reclaim|projects|apps|map|files|growth|activity|library` (`--json`;
  `library --ext` lists extensions per kind)
- distribution signing: `HEADROOM_SIGN_ID="Developer ID Application: …" HEADROOM_NOTARY_PROFILE=<profile> ./scripts/bundle.sh`
  (version from `VERSION`; Developer ID builds keep Full Disk Access across rebuilds, ad-hoc ones don't)
- Mac App Store edition: `scripts/appstore.sh [--upload]` → sandboxed universal `dist/Headroom-AppStore.pkg`
  (`-DAPPSTORE`, bundle ID `com.saphaare.headroom`, signing assets in `~/.headroom-signing`); store screenshots
  with `Headroom --render <dir> --demo --store`. See docs/APPSTORE.md.
- release: bump `VERSION`, then `HEADROOM_SIGN_ID=… HEADROOM_NOTARY_PROFILE=… HEADROOM_RELEASE_REPO=owner/public-repo
  ./scripts/release.sh "notes"` → notarized zip + `update.json` on a GitHub release. Builds with
  `HEADROOM_UPDATE_FEED` set check it daily (`Updates`); they notify and open the download, never self-install.
- design review: `.build/release/Headroom --render <dir> [--only worktrees,build-output]` draws every screen + both notch
  states to PNG from real scans (ImageRenderer can't draw ScrollView — views use
  `Scrolling {}`, which lays out flat in snapshot mode)
- demo video: `./scripts/make-reel.sh` → `dist/Headroom-demo.mp4` (`Headroom --reel <dir> --demo`
  renders captioned frames from the real flow on seeded demo data; see docs/DEMO.md)
- app icon: `Headroom --icon <png>` (bundle.sh slices it into the .icns)
- Shortcuts/Siri: bundle.sh builds with Swift const values (`scripts/appintents-protocols.json`) and runs
  `xcrun appintentsmetadataprocessor` to write `Contents/Resources/Metadata.appintents` (what Xcode would)

## Layout

- `Sources/HeadroomCore` — engine, no UI: `DiskWalker` (fts, hard-link-aware), `Catalog`
  (known space hogs + verdicts), `ProjectScanner` (build artifacts, per-project staleness),
  `Cleaner`/`SafetyGuard`, `AppInventory` (apps + Library leftovers), `DiskMap` (every GB,
  APFS volumes), `Treemap` (squarified layout), `ExternalDrive` (USB drives from IOKit) +
  `DriveCopier` (resumable drive → Mac copy)
- `Sources/Headroom` — app: `Notch.swift` (NSPanel over the camera housing), `MainView`
  (sidebar), `OverviewView`, `MapView` (treemap), `ReclaimView`, `AppsView` (+ Settings), `DrivesView` (USB drives: open read-only, browse, copy off),
  `AppModel` (state + actions), `Theme` (design system), `main.swift` (delegate, menu bar,
  monitor, notifications)
- Core, your files (all read-only): `Library` (`FileKind`, `LibraryItem`, `LibraryScanner` — your folders
  by kind, cached in `library.plist`), `LibraryQuery` (plain English → filters + chips), `DownloadSource`
  (`kMDItemWhereFroms` + the quarantine agent → Gmail, ChatGPT, a domain…), `Duplicates` (SHA-256 +
  Vision look-alikes), `TextIndex` (Vision OCR, cached in `text.plist`), `Spotlight` (mdfind/MDItem),
  `CleanUp` (the cards), `AutoRules` (optional tidy-up), `Workspace` (`Workspaces`: members by path +
  bookmark in `workspaces.json`, folder summaries, changed lately), `QuickRank` (Quick Search's tiers —
  exact > prefix > word start > anywhere > folder/tag/text > fuzzy — matched letters, and `Frecency`:
  what you open, fading over two weeks, in `quicksearch.json`), `QuickTools` (`SystemShortcuts`: what macOS
  already uses a key for, read from `com.apple.symbolichotkeys`; `QuickMath`: the calculator's own parser —
  never NSExpression, which throws; `QuickApp`: the Applications folders, listed only; `SettingsPane`: System
  Settings pages from `/System/Library/ExtensionKit/Extensions`, opened by `x-apple.systempreferences:` link)
- App, your files: `LibraryModel` (index, search, selection, view settings), `HomeView` (shelves),
  `LibraryScreens` (kinds, search + chips, saved searches, folders), `WorkspaceView` (workspace page), `FileGrid` + `FileInteraction`
  (Finder mouse: click/⌘/⇧, drag-out of many files, NSMenu), `QuickLook` (+ `HeadroomWindow`),
  `InspectorView`, `DuplicatesView` (+ Downloaded From), `CleanUpView`, `QuickSearch` (Carbon hotkey +
  panel + state; files searched off the main thread), `QuickSearchView` (sections, ⌘K actions, ⌘I info, footer),
  `QuickCommands` (commands, rows, sections, every row's actions and keys), `QuickShortcut` (the recorder), `MenuBarView` (popover), `MusicPlayer`, `Thumbnails`, `Intents` (App Intents)
- `Sources/headroom-cli` — read-only reports

## Invariants (do not break)

- The file library is read-only: `LibraryScanner`, `Spotlight`, `TextIndex` and `Duplicates` never write,
  move or delete a user file, and never read iCloud-only (dataless) files — that would download them.
  The scanner skips Library, hidden files, `node_modules`/Pods/venvs, build output inside code projects
  (a `.git` or package manifest), VM and photo-library bundles (checked before the folder test — an
  unregistered `.utm` is a plain folder), and inside code projects images and plain text.
- Removing from the library, Duplicates or a clean-up card is `AppModel.trashFiles` → `Finding.picked(.trash)`
  → `Cleaner`: always confirmed, always the Trash (never `.delete`), one Activity entry with Undo.
  Clean-up cards are never `.safe`; unused apps only when last-used is exact; Duplicates always leaves
  the keeper, and a hard link (same inode) is not a duplicate.
- Auto rules (Settings → Automatic clean up) are off by default and run at most every 6 h: old installers
  in Downloads go to the Trash through `Cleaner`; screenshots are moved by `AutoRules.perform` (guard-checked,
  never overwriting) and logged as `.filed` — Put Back moves them home; a `.filed` entry is never "in the
  Trash" or counted as freed.
- Tidy (⌥⌘T, `AutoRules.tidyPlan` → preview sheet → `AutoRules.perform`) is the only manual move of user
  files: loose files into kind folders inside the same folder, guard-checked, never overwriting, never a
  folder, one `.filed` Activity entry with Put Back. `tidyRefusal` blocks home itself, Library and anything
  inside a code project. Partial downloads, aliases/links and files changed in the last 5 minutes stay.
- Two editions from one codebase (`Edition.appStore`, `-DAPPSTORE`): the App Store edition is sandboxed, so
  it hides Memory, AI and Drives, drops `.command` findings, has no update check, no bundled CLI and no network,
  and never points users to download anything elsewhere (App Review). Use `HeadroomPaths.home`, never
  `NSHomeDirectory()` (the container inside the sandbox). Folders open through `FolderAccess`
  (security-scoped bookmarks); anything a user adds from outside home must be `remember`ed.
- Worktrees (`Worktrees`, Coding screens): found through repositories' `.git/worktrees` and `.git` files under the
  project roots + agent homes; removed ONLY by `git worktree remove` (never `--force`) as a `.command` finding,
  always `.review`. Uncommitted changes — in it or in a worktree nested inside it — make it `.keep`; an orphan
  (repository gone) goes to the Trash. Paths are compared canonicalised (`/private/var` = `/var`).
- Never wait on a permission prompt: guarded folders (Desktop, Documents, Downloads, other apps' containers,
  Mail…) go through `Access.readable` first, which looks on its own thread and gives up after a few seconds;
  a folder still waiting is skipped that scan and shown as "Waiting for permission".
- Workspaces only remember paths: adding, removing or deleting a workspace never copies, moves or
  touches a file. `Workspaces.summarize` reads like the scanner (same skips, never opens a dataless file —
  those are counted from metadata and listed as "In iCloud only"). Bookmarks resolve `.withoutMounting`.
  Renders skip `dropDestination` and text fields (`WorkspaceDrop`, snapshot mode): ImageRenderer can't draw them.
- Folder sizes (`FolderSizes.measure`, cached per path in the app's `FolderInfoStore`) reuse
  `Workspaces.summarize`'s read-only walk (`keep: 0`); "—" until measured. Grouping (`FolderGrouping`)
  only changes what's drawn — nothing moves.
- Git (`Git.swift`) is read-only: the branch from `.git/HEAD`, changes from `/usr/bin/git --no-optional-locks
  status --porcelain`, run only when `xcode-select -p` has a real git (the stub would ask to install the
  tools). Never fetch, pull or write. Home and `/` never count as a repo (dotfiles repos).
- Open in Terminal/editor (`DevApps` + `DevOpen`) uses `NSWorkspace.open(_:withApplicationAt:)`, never a shell.
- Mail's container (`~/Library/Containers/com.apple.mail`) is protected; only the contents of its
  `Data/Library/Mail Downloads` (copies of attachments you opened) may go, to the Trash only (the
  Clean up card). Never the mailboxes, never `.delete`. Reading it is `#if !APPSTORE`.
- Text recognition and duplicate detection run on this Mac only (Vision). Network stays update-check only.
- Updates notify and open the download — never self-install, even though other apps do.
- `LibraryItem` clashes with SwiftUI's DeveloperToolsSupport type: the app target has a module typealias.
- Colours are dynamic (`Theme.dynamic`, resolved by the view's colour scheme): the notch forces
  `.environment(\.colorScheme, .dark)`, renders pass `.environment(\.colorScheme, …)` (ImageRenderer
  ignores `preferredColorScheme`), and the Minimal look swaps colours for greys — MainView rebuilds its
  content with `.id(look)`. Never hardcode `Color.white` fills; use `Theme.fill(_:)`.
- Grid keys (⌘C, ⇧⌘C, ⌘A, ⌘⌫, Space, arrows) are `onKeyPress` on the focused grid, so they never steal
  copy/paste from a text field. Keys bubble up from children, so never put a text field inside a
  `FileGrid` header (Space would open Quick Look, Return the focused file) — put it above the grid. ⌘1–9 = Home, Recents, Images, Videos, Music, Documents, Archives, Apps,
  Overview; ⌃1–9 workspaces, ⌥⌘N new workspace, ⌥⌘T tidy, ⌥⇧⌘T/⌥⇧⌘E folder in terminal/editor; ⌃⌘1/⌃⌘2 grid/list, ⌘I info, ⇧⌘D/⇧⌘K/⇧⌘J Duplicates/Clean up/Downloaded from, ⌃⌘T look,
  ⌃⌥Space Quick Search (system-wide; Settings records any keys and warns when macOS owns them — Carbon
  registers ⌘Space even while Spotlight has it, so the status comes from `SystemShortcuts`, not the
  registration). In Quick Search: ↩/⌘↩/⌥↩, ⌘K actions, ⌘I info, ⌘Y Quick Look, ⌘1–9 pick, ⌃N/⌃P, ⌘↑/⌘↓
  sections, esc clears then closes; Move to Trash there opens the window's confirm (Cleaner, Undo).

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
  confirms first. `.keep` folders (your data) may only be moved to the Trash, with the explainer's
  warning in the confirm — never emptied or deleted for good; anything inside a real `.app` bundle
  and any `.photoslibrary` are refused (apps are uninstalled whole, via `AppInventory`).
- `Explainer` (Core) says what any path is, what deleting it means and who owns it; the map's
  `MapInspector` shows it beside the selection with every action as a button. An app's data folder
  offers "Uninstall <App> completely" (app + all leftovers, one Activity entry, Undo).
- Leftovers match the bundle ID exactly or with a `.suffix` (ShipIt updaters, extensions, helpers)
  unless that suffixed ID is another installed app; exact app/executable names count only in
  Application Support, Caches and Logs, never generic executables (Electron, launcher…).
- The guard also refuses git history (`.git` and inside) and live VM disks (`~/.colima`,
  `~/.lima`, `~/.orbstack`…) — except for a `.command` finding (the tool's own prune), and copies
  in `<vm home>/backups/` going to the Trash (never `.delete`). `DevTools.vmDiskBackups` offers them
  only while `dockerDiskHealth()` is clean (Docker answers, no disk errors in the VM's kernel log);
  otherwise they are `.keep`. Only
  `xcrun simctl` may reach `/Library/Developer/CoreSimulator`. A finding with no paths never runs.
- Never-touch list (`SafetyGuard.excluded`, UserDefaults `neverTouch`): refused at, inside or
  containing an excluded path; `Exclusions.apply` hides them from scans.
- Every removal is logged to `ActivityLog` (Application Support/Headroom/activity.json) with
  where trashed items landed; Put Back never overwrites. "Delete for good" in Activity
  (`ActivityLog.deleteFromTrash`) removes only an entry's own copies inside `~/.Trash`, via `Cleaner`
  (`.delete` picked findings) — never anything else in the Trash, and `~/.Trash` itself is protected. An uninstalled `.app` directly in `~/.Trash` may be deleted whole (`.delete` only), never a piece of it. Auto-reclaim (off by default) is the
  safe set only, at most every 6 h.
- Bulk actions (Large files, Apps) always confirm first and land as one Activity entry; the
  window toast offers Undo (= Put Back) for anything trashed. Shortcuts: ⌘1–9 screens, ⌘R rescan,
  ⌘A select all, ⌘⌫ trash selection, ⌥⌘⌫ delete permanently (Large files only), ⌘Z undo from the toast.
- AI (`AIUsage` + `AIView`): models are `.review` and go to the Trash, except Ollama's (`ollama rm`, `.none` without the
  command); AI caches `.safe`, session history `.keep`. Servers come from `lsof`; stopping one goes through `ProcessGuard`.
  iPhone/iPad backups are one `.review` finding per device, Trash only — never the Backup folder itself.
- Memory (`Memory.swift`): `ProcessGuard` is the ONLY code that stops processes — yours only (same
  uid), never pid ≤ 1, Headroom itself, session-essential names (WindowServer, Finder, Dock…) or system
  paths (/System, /usr except /usr/local, /sbin, /bin). `stop` re-checks uid and start time first (pids
  get reused). Apps quit via `NSRunningApplication.terminate` (they can save); force quit always confirms.
  Never `purge` or "free" cached memory — it only slows the Mac down.
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
- Drives (`ExternalDrive`/`DrivesView`) read IOKit (`ioreg`) and the mount table, never `diskutil`:
  while macOS checks a drive before mounting, diskutil and Disk Arbitration hang. The check's progress
  is the disk's IOKit "Bytes (Read)" sampled over time. Headroom only ever reads a drive: "Check & open"
  is `diskutil mount` (macOS checks, then mounts it normally — run detached, it waits for the check);
  "Open now" mounts read-only (admin prompt via osascript) and `DriveCopier` copies into `~/Drive Rescue`
  without deleting anything (it truncates/replaces only its own copies). Never offer to skip the check
  for exFAT/FAT under FSKit (`fsKitOwnsWindowsFormats`, macOS 26+): the kext can't load and FSKit won't
  mount an unchecked volume even read-only, so killing the check only leaves the drive unopened.
