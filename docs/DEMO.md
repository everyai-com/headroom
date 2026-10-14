# Recording a Headroom demo

## The fast way: let Headroom make the video

```bash
./scripts/make-reel.sh              # → dist/Headroom-demo.mp4 (1080p, ~45 s, ~6 min to build)
./scripts/demo-clean.sh             # afterwards: remove the demo data
```
It seeds fresh demo data. Headroom then runs the real flow on it (scan, map, reclaim the idle
demo projects, trash a big file, put it back), renders 12 captioned frames, and ffmpeg cuts
them together with slow push-ins and crossfades. Nothing outside `~/Desktop/headroom-demo`
(and the two demo files) is touched, and the app's own history and activity logs are restored
afterwards. Edit captions and timings in `Sources/Headroom/Reel.swift`.

## The live way: record the screen yourself

A ~2-minute screen recording that shows the whole story: **see where every GB went → get it
back safely → undo anything**. Everything deleted on camera is fake demo data.

## 1. Before you record (10 min)

**Data**
```bash
./scripts/bundle.sh                 # latest build, installed as ./Headroom.app
./scripts/demo-seed.sh              # ~7 GB of fake projects, an old installer, a big video
pkill -x Headroom; open Headroom.app --args --demo --open
```
`--demo` limits Reclaim's projects and Large files to the demo data, so your real projects and
documents never appear. The map still shows your real top-level folders; only drill into
**Desktop → headroom-demo** on camera.

Wait until the sidebar's free space settles and the map has finished (Overview → "Where your
space goes" is filled in). Then press **Rescan** once more, so "What grew" shows
`headroom-demo` (+7 GB) against the first map.

**Screen**
- Do Not Disturb on (Control Center → Focus), so no notifications appear on screen.
- Hide desktop icons: `defaults write com.apple.finder CreateDesktop false; killall Finder`
  (undo: `… CreateDesktop true`).
- Quit chat, mail, password manager. Close other windows.
- The notch shots need a MacBook with a notch, recorded at the built-in display's default
  resolution. On an external display Headroom shows a centred pill instead.
- Settings → Show in the notch: on. Settings → Reclaim automatically: off (you'll show it, not trigger it).

**Recorder:** ⌘⇧5 → "Record Selected Portion" (or Entire Screen for the notch),
Options → Show Mouse Clicks. Or use Screen Studio / CleanShot for auto-zoom.

## 2. Run of show

| # | Time | On screen | Say (suggested) |
|---|---|---|---|
| 1 | 0:00 | Desktop, cursor moves up to the **notch** and hovers — the panel drops down with free space and the top safe wins | "My Mac is always running out of space. Headroom lives in the notch." |
| 2 | 0:10 | Click the **expand button** (↖↘, top right of the panel) → **Overview**. Linger on the big free-space number and the gauge | "It shows where every gigabyte goes — including the parts macOS hides." |
| 3 | 0:20 | Scroll to **What grew** → `headroom-demo +7 GB` | "And what grew since yesterday. Agents spin up repos all day — this is where the space went." |
| 4 | 0:30 | **Map**. Hover a few squares. Double-click **Desktop** → **headroom-demo**. The mint, hatched squares are safe | "Every GB as a square. Green means safe to delete — build output your tools recreate." |
| 5 | 0:45 | Click **checkout-agent** → bottom bar. Right-click it to show the full menu, then close it | "Pick anything. Reveal it, open it in Terminal, trash it, or delete it." |
| 6 | 0:55 | **Reclaim** → **By project**. Show live-dashboard as "Review first" (touched today) vs the idle ones | "It knows which projects you're working on. Idle ones are safe; today's need a look." |
| 7 | 1:05 | **Select every project idle 30+ days** → **Reclaim** in the bottom bar. The number counts up | "One click. Only regenerable output — `pnpm install` brings it back exactly." |
| 8 | 1:20 | **Large files** → `headroom-demo-recording.mov` (1.2 GB) → **Move to Trash…** → confirm | "Big single files the folder view hides — a forgotten recording." |
| 9 | 1:30 | **Activity** → the reclaim, with its rebuild commands, and the trashed video → **Put Back** | "Everything is logged. Changed your mind? Put it back." |
| 10 | 1:40 | **Settings** → Never touch, Reclaim automatically | "Mark folders it must never touch, and let it reclaim on its own when space runs low." |
| 11 | 1:50 | Terminal: `./headroom-cli status --json` | "And your coding agents can check disk space before a big install." |
| 12 | 1:55 | Back to the notch, free space higher than at the start | "Headroom." |

**Shots worth a second take:** the notch hover (1), the map drill-in (4) and the Reclaim count-up (7).
Record them as separate clips and cut them together.

## 3. After recording

```bash
./scripts/demo-clean.sh             # removes all demo data, including copies in the Trash
pkill -x Headroom; open Headroom.app
defaults write com.apple.finder CreateDesktop true; killall Finder
```

## Re-take checklist

Reclaiming deletes the demo `node_modules`, so for another take run `./scripts/demo-clean.sh`,
then `./scripts/demo-seed.sh`, then press **Rescan**.
