#!/bin/bash
# Fake, harmless data for recording a Headroom demo — so the camera never shows your real
# projects or files. ~7 GB of zero-filled files. Remove everything with scripts/demo-clean.sh.
#
#   ~/Desktop/headroom-demo/   3 idle agent-made projects (safe), 1 active one (review), 1 idle Rust project
#   ~/Downloads/Figma-Installer-demo.dmg      an "old installer" (60 days)
#   ~/Movies/headroom-demo-recording.mov      a big forgotten video (Large files → Trash → Put Back)
set -euo pipefail
DEMO="$HOME/Desktop/headroom-demo"
OLD=$(date -v-60d +%Y%m%d%H%M)

FREE_GB=$(df -g "$HOME" | awk 'NR==2 {print $4}')
if [ "$FREE_GB" -lt 15 ]; then echo "Need 15 GB free to seed the demo (have ${FREE_GB} GB)."; exit 1; fi

blob() { mkdir -p "$(dirname "$1")"; mkfile "$2" "$1"; }   # real (non-sparse) bytes
old() { touch -t "$OLD" "$@"; }

node_project() { # name, node_modules size, .next size, idle?
  local d="$DEMO/$1"
  mkdir -p "$d/src"
  printf '{ "name": "%s", "private": true }\n' "$1" > "$d/package.json"
  touch "$d/pnpm-lock.yaml" "$d/README.md"
  echo "export default function App() {}" > "$d/src/app.tsx"
  blob "$d/node_modules/.pnpm/deps.bin" "$2"
  [ "$3" != "0" ] && blob "$d/.next/cache/webpack.pack" "$3"
  if [ "$4" = "idle" ]; then old "$d/package.json" "$d/pnpm-lock.yaml" "$d/README.md" "$d/src"; fi
}

echo "Seeding demo data in $DEMO …"
node_project checkout-agent   900m 400m idle
node_project landing-page-v3  800m 500m idle
node_project invoice-bot      700m 0    idle
node_project live-dashboard   600m 300m active   # touched today → "Review first"

R="$DEMO/pricing-engine"
mkdir -p "$R/src"
printf '[package]\nname = "pricing-engine"\nversion = "0.1.0"\n' > "$R/Cargo.toml"
echo "fn main() {}" > "$R/src/main.rs"
blob "$R/target/debug/deps.bin" 700m
old "$R/Cargo.toml" "$R/src"

blob "$HOME/Downloads/Figma-Installer-demo.dmg" 800m
old "$HOME/Downloads/Figma-Installer-demo.dmg"
blob "$HOME/Movies/headroom-demo-recording.mov" 1200m
old "$HOME/Movies/headroom-demo-recording.mov"

echo "Done. In Headroom press Rescan (top right) and wait for the map to finish."
