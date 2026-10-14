#!/bin/bash
# Remove everything demo-seed.sh created — including copies the demo moved to the Trash.
set -uo pipefail
rm -rf "$HOME/Desktop/headroom-demo"
rm -f "$HOME/Downloads/Figma-Installer-demo.dmg" "$HOME/Movies/headroom-demo-recording.mov"
find "$HOME/.Trash" -maxdepth 1 \( -name 'headroom-demo*' -o -name 'Figma-Installer-demo*' \
  -o -name 'checkout-agent*' -o -name 'landing-page-v3*' -o -name 'invoice-bot*' -o -name 'live-dashboard*' \
  -o -name 'pricing-engine*' \) -exec rm -rf {} + 2>/dev/null
echo "Demo data removed. Rescan in Headroom to refresh."
