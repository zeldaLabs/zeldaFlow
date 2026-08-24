#!/bin/bash
# Build and install zeldaFlow.app to /Applications, then launch it.
# On a fresh machine this is the only command you need — it runs setup
# (models + llama.cpp) when the models aren't there yet.
# Keep the install path stable — macOS TCC permissions are keyed to it.
set -euo pipefail
cd "$(dirname "$0")/.."

# setup.sh is idempotent and near-instant when everything already exists —
# running it every time also repairs partial setups (one model missing, etc.).
scripts/setup.sh

scripts/build-app.sh release

DEST="/Applications/zeldaFlow.app"
echo "==> installing to $DEST"
# Quit a running instance so the binary isn't busy. pkill, not AppleScript:
# a pending Automation permission prompt makes osascript hang indefinitely.
pkill -x zeldaFlow >/dev/null 2>&1 || true
sleep 1
rm -rf "$DEST"
ditto "build/zeldaFlow.app" "$DEST"

echo "==> launching"
open "$DEST"
echo "Done. Look for the waveform icon in the menu bar."
