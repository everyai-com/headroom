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
- read-only reports: `./headroom-cli status|reclaim|projects|apps|map|files|growth|activity|library|battery` (`--json`;
  `library --ext` lists extensions per kind)
- planner: `./headroom-cli today | add "…" [--big] [--tomorrow|--day YYYY-MM-DD|--inbox] [--project p] [--from claude] |
  done <n|words> | later <n|words> | habits | habit add "…" [--identity --cue --two-minute --at HH:MM --days mon,wed --area a --avoid] |
  habit done | habit slip | focus [start "…"|<n>] | focus stop | rewards | reward add "…" <coins> | buy <n|words> |
  challenge add "<habit>" <times> [--days 30] | stats | season [set "<main>" 20 ["<side>" 8] | end]` (add also takes
  `--effort 1-3 --area a`; `habit add --minutes 240 --track <project>` (or `--area <area>`) is a daily quest that fills from the timeline).
  `./headroom-cli timeline [--day D] [--json]` (read-only) says where a day went — read it before planning someone's day.
  `timeline teach <app|host|title|project> "<value>" --project/--area/--kind` writes only `timeline/rules.json`; the app
  reloads it on its next tick. Project rules apply last, to the project a span ended up with.
  `journal ["how it went"] [--mood 1-5 --energy 1-5]` appends to today's entry (no text = show it); `sleep` (read-only) lists
  the nights the Mac saw; `habit add "Commit something" --commit [project]` is checked off by the first commit of the day.
  `blocks [--day D]` · `block add "<title>" 09:30 11:00 [--project p]` · `block remove <n>` are time blocks (planner.json only);
  `season` prints the week-by-week grid (● on track ◐ adjust ○ off track); `season set … --weeks 1-12`; `season end` keeps it for `wrap`.
  `milestones` · `milestone add "…" [--project p] [--due D|--week n]` · `milestone done|pin <n|words>` · `protect [add "<project>" weekdays
  09:00 11:00 | remove <n>]` · `stack [--keep]` (today's tasks into free time) · `top [<n|words>] [--tomorrow]` · `sync <1-4>` · `score` · `wrap`.
  `vision [become|do|have|picture|wait "…" | read]` · `grateful "…" …` · `gave "…"` · `way [check <item>]` (the certain way).
  — the only CLI commands that write, and only Headroom's own `planner.json`. Use them to plan the user's day from a session.
- distribution signing: `HEADROOM_SIGN_ID="Developer ID Application: …" HEADROOM_NOTARY_PROFILE=<profile> ./scripts/bundle.sh`
  (version from `VERSION`; Developer ID builds keep Full Disk Access across rebuilds, ad-hoc ones don't)
- Mac App Store edition: `scripts/appstore.sh [--upload]` → sandboxed universal `dist/Headroom-AppStore.pkg`
  (`-DAPPSTORE`, bundle ID `com.saphaare.headroom`, signing assets in `~/.headroom-signing`); store screenshots
  with `Headroom --render <dir> --demo --store`. See docs/APPSTORE.md.
- release: bump `VERSION`, then `HEADROOM_SIGN_ID=… HEADROOM_NOTARY_PROFILE=… HEADROOM_RELEASE_REPO=owner/public-repo
  ./scripts/release.sh "notes"` → notarized universal `Headroom.dmg` (the README's Download link,
  `releases/latest/download/Headroom.dmg`) + zip + `update.json` on a GitHub release (Developer ID builds are
  arm64 + x86_64 in `.build/universal`; ad-hoc ones build this Mac's arch only). Builds with
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
  `QuickCommands` (commands, rows, sections, every row's actions and keys), `QuickShortcut` (the recorder), `MenuBarView` (popover; Eject for every external volume, from the mount table), `MusicPlayer`, `Thumbnails`, `Intents` (App Intents)
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
- Notepad (`Notes` + `NoteEditor`/`NoteWindows`): New File (folder screen, Drives) makes an empty .md/.txt with
  `.withoutOverwriting` — never in Library, inside a bundle or outside home + /Volumes. Opening a .md/.txt opens it in
  Headroom (≤ 5 MB, never a dataless iCloud file). Saves rewrite only the open file and refuse when its date on disk
  changed since it was read (another app's edit) until you pick Keep Mine; dates are read fresh (a URL caches them).
  `Notes.add` copies dropped/picked files onto a drive, skipping names already there. Nothing here deletes.
- Text recognition and duplicate detection run on this Mac only (Vision). Network stays update-check only.
- Planner add-on (`Planner.swift` + `TodayView`/`NotchTodayView`/`QuickAdd`, Settings → Add-ons, on by default): tasks and
  habits in `planner.json`, written by the app AND the CLI — every write is `PlannerStore.mutate` (re-read, change, save),
  never a save of a stale copy; the app reloads on the file's date each tick. At most `Planner.bigLimit` (3) big tasks a day,
  finished ones included. XP and levels are computed from what's done (never stored); streaks are "never miss twice"
  (one missed planned day bends, two in a row break; today isn't a miss until it's over; days before the habit existed never
  are). ⌃⌥N (Carbon, only while the add-on is on — never ⌥N, which types ñ) opens quick add; habit nudges notify once a day within 2 h of their time.
  Gamification stays white-hat: no penalties, no streak loss for a single miss, nothing that costs money or time to "protect".
  The game layer (`Progression.swift`, Progress screen `JourneyView`, after the LiFE RPG Notion template minus its HP/death/
  overdraft mechanics): `Planner.ledger` derives every XP and coin from what's done — task 10×effort (+20 big), habit check-in
  10 (+2/planned day in a row, max +10), avoid-habit 5 per finished clean day, focus 20/h (≥ 5 min, ≤ 3 h a session, only
  once stopped), won challenge min(300, 10×target); coins = XP earned − purchases, never stored, and buying needs the coins
  (no debt). Areas level on their own (step 50). A slip only restarts an avoid-habit's clean run; an ended challenge costs
  nothing. Quick capture: "#area" and "!!"/"!!!" (effort) in any add field.
- Timeline (`Timeline.swift` + `Quests.swift` in Core, `ActivityRecorder` + `TimelineScreen`/`LifeHome` in the app; Life
  section of the sidebar): OFF until the user turns it on, never in the App Store edition. Every 10 s while the user is at
  the keyboard (idle < 3 min; 30 min for video and calls) it notes the front app, the window title only if Accessibility is
  already trusted, and for browsers the HOST only (never the URL), only if macOS already allows Automation for that browser —
  checked with `AEDeterminePermissionToAutomateTarget(ask: false)`; prompts come only from the Timeline screen's buttons, on a
  background queue. Incognito windows, password managers and excluded apps/sites are never recorded. Days live in
  `timeline/<day>.json` for 30 days (`TimelineStore.prune`), rules in `timeline/rules.json`; "Forget today" deletes the file.
  Nothing is uploaded. Claude Code time is read (never written) from `~/.claude/projects/*/*.jsonl` (user/assistant
  timestamps < 5 min apart = one stretch; worktrees count as their repository). Overlaps count once (`TimelineMath.covered`).
  Timed habits (`minutes` + `track`) are checked off by `Planner.applyQuotas` on the tick — never unchecked. A season is one
  main + at most 2 side projects with hours/week, compared to the week's tracked minutes.
- Coach (`Coach.swift` in Core, `LifeCoach` + `CoachCard`/`CoachSheet` on Today; full edition only): the calendar is read
  through EventKit only after the user presses Connect Calendar (never prompted from the tick). The only write is the opt-in
  "Show my time blocks in Calendar" (`CalendarMirror.plan` is pure; `LifeCoach.mirror` applies it): blocks for today + 7 days
  are copied into a calendar Headroom makes called "Headroom" (its id in UserDefaults), at most once a minute — never any other
  calendar, never an event it didn't make (block → event ids in UserDefaults `mirroredBlocks`); past events stay as a record;
  turning it off removes only its own events from today on. Events in that calendar are left out of "busy" reading. Proof is your
  own commits (`git log --author=<repo user.email>`, optional locks off) in the repositories behind Claude Code projects —
  read-only like `Git.status`. The coach runs the user's own `claude -p` ONLY when they press Plan/Review, with `--tools ""
  --strict-mcp-config --no-session-persistence` (no tools, no MCP, no log that would count as timeline time); its reply is a
  suggestion — nothing is added until the user ticks it and presses Add (`Planner.accept`: a matching open task is moved,
  never duplicated; the Big 3 limit holds). Drift nudges come from the pure `Nudges.decide`, only while the timeline is on.
- Life log (`LifeLog.swift` in Core, `DayLogCard` on Today, `HabitMonthCard` on Progress): one `DayLog` a day in planner.json —
  journal (+10 XP only with ≥ 5 words) and check-in (+5 only with both mood and energy), both derived by the ledger, so clearing
  one takes its XP back. "Reflect with Claude" runs the same no-tools `claude -p` only on that button, and saves the reply beside
  the entry. Proof habits (`Habit.proof`) are checked by `Planner.applyProof` from today's commits — never unchecked. Detected
  focus (`FocusDetector`, timeline on only): ≥ 40 min in one project, gaps ≤ 5 min, cut by any distraction ≥ 2 min, finished
  stretches only; recorded as `FocusSession(detected: true)` never over an existing session, split at the 3 h cap. Sleep is an
  estimate from `rest.json` (sleep/wake/lock/unlock/screen times only, 30 days) — `Rest.night`, longest overnight rest, short
  wake-ups under 20 min joined; never `pmset`. The month view is a mirror: missed days are outlined, never red.
- Focus plan (`FocusPlan.swift` in Core, `DayPlanCard`/`SeasonGrid`/`FocusShield`/`FocusQuality` in the app; after
  Superfocus): seasons run 1–12 weeks in 7-day weeks from their first day; `Season.log` keeps each week's minutes per quest
  (written only when changed) so the grid outlives the timeline's 30 days; `Season.status` judges the current week on pace.
  Time blocks live in planner.json (mirrored to the "Headroom" calendar only when that's switched on) and never overlap (`addBlock` returns nil). Plan
  strength = hours still needed this season week that have a block ahead. Coach replies may carry `blocks` and
  `recommendations` (`.week` review); blocks land only when ticked and Added (`acceptBlocks`, clashes skipped). Focus quality
  is the share of a session not on distractions (timeline). The shield (off / remind / hide, default remind) acts only during a
  running session: `FocusMode.react` is pure; hiding is `NSRunningApplication.hide()` for apps — never quit, never a browser
  for one tab — reminders at most every 5 min. No website blocking (that would need /etc/hosts or admin rights).
  The shield's pause mode (`PauseCard`) is friction instead: a card over the screen for a distracting app or site — Back to
  Work hides an app (a browser: Headroom comes forward), or a 10 s wait buys 5 minutes of that site/app (in memory only).
  Nothing is closed or blocked.
- Vision and the certain way (`Vision.swift` in Core, `VisionCard`/`VisionSheet`/`VisionEditor` on Today, after Wattles' "The
  Science of Getting Rich"): `Planner.vision` (have/do/become, the picture, decisions parked 2 days — "when in doubt, wait"),
  `DayLog.gratitude` (3 lines, +5), `gave` (use value given, +5), `visioned` (+5), `ways` (self-ticked practices; 3+ = +10).
  `CertainWay.met` reads vision/gratitude/value/all-planned-done from the day — those can't be ticked by hand. All derived by the
  ledger. CLI: `vision [become|do|have|picture|wait "…" | read]`, `grateful "…"`, `gave "…"`, `way [check <item>]`.
- Today's spine (`DayPath.swift` in Core, `PathViews.swift` in the app): `DayPath` reads ten steps (vision, Big 3, top thing,
  blocks, focus; three thanks, value given, rating, journal, tomorrow's top thing) from planner.json and offers exactly one next
  step for the time of day — the only primary button on Today. `SetupCard` lists what's left of the system setup (vision,
  season, calendar, blocks on the phone, routines, pause shield) until done or hidden. `EveningSheet` closes the day in one place.
- Routines and meeting prep (`Routines.swift` in Core, `RoutinesSheet` from the Coach card's alarm button): a notification at
  the morning/evening/weekly times (once a day each, within 2 h, the evening one skipped once the day is rated) and 10 min
  before a timed calendar event. Only the notification's button or the card's Prep/Plan buttons run the coach — a nudge
  never does on its own. Meeting prep reads the event's notes and attendee names (EventKit, read-only); its agenda stays in
  the sheet (Copy Agenda), never the day's note.
- Season plan (`SeasonPlan.swift` in Core, `SeasonViews.swift` in the app; the rest of Superfocus): milestones per quest (+30 XP
  when ticked, derived by the ledger; a milestone due in a week and done late or not at all turns that week's on track into
  adjust), protected weekly hours per quest (drawn as blocks, never stored; nothing else lands in them; they count toward plan
  strength), support areas, a signed commitment, and `pastSeasons` for the wrap (`endSeason`). Daily score = planned tasks,
  unlinked blocks and build habits done × 90% + the daily sync (`DayLog.progress`, +5 XP) × 10%. `DayLog.top` is the day's one
  task; the shield guards it only when "Guard today's top thing" is on. How sessions/blocks felt (`Feel`) feeds `EnergyPatterns`
  and the coach. The stack (`Planner.stack`) only proposes blocks — kept when you press Keep. The coach's memory is the user's
  own `coach-memory.md`, sent with every prompt; coach `remember` lines and season drafts (`Coach.seasonPrompt` → `SeasonDraft`)
  are applied only when ticked/saved. Focus sound is noise generated on the Mac (`AVAudioSourceNode`), nothing streamed.
- Battery add-on (`Battery.swift` + `BatteryView`, Settings → Add-ons, on by default, hidden without a battery) is read-only:
  `AppleSmartBattery` properties from IOKit, never SMC writes, a helper or `pmset` — Headroom never changes charging; tips point
  to System Settings › Battery. Health = `AppleRawMaxCapacity / DesignCapacity` (`MaxCapacity` is a % on Apple silicon). Readings
  (≤ one per 4 min, from the 30 s tick) go to `battery.json`; gaps over 20 min aren't counted as hours. The month card never shows
  the Mac's name (it's meant to be shared).
- Keep awake (`KeepAwake.swift`, menu bar row `KeepAwakeRow`): only macOS's own idle-sleep assertion (`IOPMAssertionCreateWithName`,
  what `caffeinate` does) — no admin rights, no `pmset`, released when the session ends or Headroom quits. The rules are the pure
  `KeepAwake.decide` (time's up → battery cutoff, only unplugged → charger required → while agents: your own `claude`/`codex`/builds).
  Energy (`Energy.swift`, `EnergyCard` on the Battery screen) reads CPU time + wake-ups (`proc_pid_rusage`) and sleep blockers
  (`IOPMCopyAssertionsByProcess`); quitting goes through `ProcessGuard` like Memory.
- Updates notify and open the download — never self-install, even though other apps do.
- `LibraryItem` clashes with SwiftUI's DeveloperToolsSupport type: the app target has a module typealias.
- Colours are dynamic (`Theme.dynamic`, resolved by the view's colour scheme): the notch forces
  `.environment(\.colorScheme, .dark)`, renders pass `.environment(\.colorScheme, …)` (ImageRenderer
  ignores `preferredColorScheme`), and the Minimal look swaps colours for greys — MainView rebuilds its
  content with `.id(look)`. Never hardcode `Color.white` fills; use `Theme.fill(_:)`.
- Design locks (after Appllama's anti-slop pre-flight): type sizes 9 10 11 12 13 15 17 22 28 (34+ only for hero numbers
  and icons); corner radii 4 bars · 8 ghost controls · 12 buttons, rows, fields · 16 inner panels · 20 cards, always
  `.continuous`, chips are Capsules. One accent (`Theme.accent`) for actions, done ticks and progress; the primary button
  is a flat fill — no gradient, no glow — pressed with a 0.12 s ease-out (no scale under Reduce Motion). The window and
  notch roots set `.monospacedDigit()`. No emoji or ✓ glyphs in chrome — SF Symbols.
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
  is the disk's IOKit "Bytes (Read)" sampled over time. Headroom never deletes or changes what's on a drive;
  it writes to one only when you ask (New File, Add Files…/drop, the notepad — `Notes`), only on a drive macOS
  mounted read-write, never replacing a file: "Check & open"
  is `diskutil mount` (macOS checks, then mounts it normally — run detached, it waits for the check);
  "Open now" mounts read-only (admin prompt via osascript) and `DriveCopier` copies into `~/Drive Rescue`
  without deleting anything (it truncates/replaces only its own copies). Never offer to skip the check
  for exFAT/FAT under FSKit (`fsKitOwnsWindowsFormats`, macOS 26+): the kext can't load and FSKit won't
  mount an unchecked volume even read-only, so killing the check only leaves the drive unopened.
  Don't run `fsck_exfat` from the app either: a root shell from an admin prompt (osascript/authtrampoline)
  doesn't inherit the app's Full Disk Access, so raw `/dev/rdisk*` reads fail with EPERM — and the classic
  check isn't clearly faster on a full drive (tried on a 1.7 TB SSD: FSKit's check took 30 min over USB 2.0).
