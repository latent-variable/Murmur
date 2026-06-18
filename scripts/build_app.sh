#!/usr/bin/env bash
# Assemble Murmur.app from the SwiftPM build. Bundles the Python backend
# sources (not the venv/models — those live in Application Support).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPDIR="$ROOT/app"
CONFIG="${1:-release}"
OUT="$ROOT/dist"
APP="$OUT/Murmur.app"

echo "[build] swift build -c $CONFIG"
( cd "$APPDIR" && swift build -c "$CONFIG" )
BIN="$(cd "$APPDIR" && swift build -c "$CONFIG" --show-bin-path)/Murmur"

echo "[build] assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/repo"

cp "$BIN" "$APP/Contents/MacOS/Murmur"
cp "$ROOT/app/Resources/Info.plist" "$APP/Contents/Info.plist"

# Bundle backend sources + launcher so a packaged app can run self-contained.
cp -R "$ROOT/backend/server.py" "$ROOT/backend/download_models.py" \
      "$ROOT/backend/requirements.txt" "$APP/Contents/Resources/repo/" 2>/dev/null || true
mkdir -p "$APP/Contents/Resources/repo/backend" "$APP/Contents/Resources/repo/scripts"
cp "$ROOT/backend/server.py" "$ROOT/backend/download_models.py" \
   "$ROOT/backend/requirements.txt" "$APP/Contents/Resources/repo/backend/"
cp "$ROOT/scripts/run_backend.sh" "$APP/Contents/Resources/repo/scripts/"
chmod +x "$APP/Contents/Resources/repo/scripts/run_backend.sh"

# Ad-hoc sign so TCC (Accessibility) keeps a stable identity for the bundle.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "[build] codesign skipped"

echo "[build] done -> $APP"
