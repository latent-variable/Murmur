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

# App icon (regenerate if the generator is newer than the icns).
if [ ! -f "$ROOT/app/Resources/AppIcon.icns" ] || \
   [ "$ROOT/scripts/make_icon.swift" -nt "$ROOT/app/Resources/AppIcon.icns" ]; then
  echo "[build] rendering app icon"
  swift "$ROOT/scripts/make_icon.swift" >/dev/null
  iconutil -c icns "$ROOT/dist/AppIcon.iconset" -o "$ROOT/app/Resources/AppIcon.icns"
fi
cp "$ROOT/app/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Bundle backend sources + launcher so a packaged app can run self-contained.
cp -R "$ROOT/backend/server.py" "$ROOT/backend/download_models.py" \
      "$ROOT/backend/requirements.txt" "$APP/Contents/Resources/repo/" 2>/dev/null || true
mkdir -p "$APP/Contents/Resources/repo/backend" "$APP/Contents/Resources/repo/scripts"
cp "$ROOT/backend/server.py" "$ROOT/backend/download_models.py" \
   "$ROOT/backend/requirements.txt" "$APP/Contents/Resources/repo/backend/"
cp "$ROOT/scripts/run_backend.sh" "$APP/Contents/Resources/repo/scripts/"
chmod +x "$APP/Contents/Resources/repo/scripts/run_backend.sh"

# Embed the self-contained Python runtime so the app needs no system Python.
# Built by scripts/bundle_python.sh (cached). Without it, the app falls back to
# building a venv from system Python (dev machines only).
if [ "${MURMUR_BUNDLE_PYTHON:-1}" = "1" ]; then
  if [ ! -x "$ROOT/dist/python-runtime/bin/python3" ]; then
    bash "$ROOT/scripts/bundle_python.sh"
  fi
  echo "[build] embedding Python runtime"
  ditto "$ROOT/dist/python-runtime" "$APP/Contents/Resources/python"
fi

# Prefer a stable self-signed identity (survives reinstalls → Accessibility
# grant persists). Falls back to ad-hoc. Set one up with scripts/setup_signing.sh.
SIGN_ID="Murmur Local Signing"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "$SIGN_ID"; then
  echo "[build] signing with '$SIGN_ID' (stable identity)"
  codesign --force --deep --sign "$SIGN_ID" "$APP" >/dev/null 2>&1 \
    || { echo "[build] stable signing failed, falling back to ad-hoc"; codesign --force --deep --sign - "$APP" >/dev/null 2>&1; }
else
  echo "[build] ad-hoc signing (run scripts/setup_signing.sh for a persistent identity)"
  codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "[build] codesign skipped"
fi

echo "[build] done -> $APP"
