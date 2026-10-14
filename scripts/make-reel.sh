#!/bin/bash
# Make the Headroom demo video, start to finish, without touching your real files:
#   fresh demo data → the app runs the real flow on it and renders captioned frames → ffmpeg cuts
#   them into dist/Headroom-demo.mp4 (1080p, ~50 s) with gentle zooms and crossfades.
# Needs ffmpeg (brew install ffmpeg). Reclaims only ~/Desktop/headroom-demo (see demo-seed.sh).
set -euo pipefail
cd "$(dirname "$0")/.."
command -v ffmpeg >/dev/null || { echo "ffmpeg not found — brew install ffmpeg"; exit 1; }

swift build -c release --product Headroom >/dev/null
./scripts/demo-clean.sh >/dev/null
./scripts/demo-seed.sh
FRAMES=$(mktemp -d)/reel
.build/release/Headroom --reel "$FRAMES" --demo

mkdir -p dist
OUT=dist/Headroom-demo.mp4
python3 - "$FRAMES" "$OUT" <<'PY'
import subprocess, sys
frames, out = sys.argv[1], sys.argv[2]
shots = [l.split() for l in open(f"{frames}/shots.txt") if l.strip()]
fade = 0.6
args, chains = ["ffmpeg", "-y", "-loglevel", "error"], []
for i, (name, secs) in enumerate(shots):
    d = float(secs)
    args += ["-loop", "1", "-framerate", "30", "-t", str(d), "-i", f"{frames}/{name}"]
    n = int(d * 30)
    # Slow push-in (2.5%), alternating toward the centre so cuts feel alive.
    chains.append(f"[{i}:v]scale=3840:2160,zoompan=z='1+0.025*on/{n}':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)'"
                  f":s=1920x1080:fps=30,setsar=1,format=yuv420p[v{i}]")
prev, offset = "v0", 0.0
for i in range(1, len(shots)):
    offset += float(shots[i - 1][1]) - fade
    chains.append(f"[{prev}][v{i}]xfade=transition=fade:duration={fade}:offset={offset:.2f}[x{i}]")
    prev = f"x{i}"
chains.append(f"[{prev}]fade=t=in:st=0:d=0.5,fade=t=out:st={offset + float(shots[-1][1]) - 0.8:.2f}:d=0.8[out]")
args += ["-filter_complex", ";".join(chains), "-map", "[out]", "-c:v", "libx264", "-preset", "slow", "-crf", "18",
         "-pix_fmt", "yuv420p", "-movflags", "+faststart", out]
subprocess.run(args, check=True)
PY
echo "demo video: $(pwd)/$OUT ($(du -h "$OUT" | cut -f1))"
echo "frames: $FRAMES   ·   remove the demo data with ./scripts/demo-clean.sh"
