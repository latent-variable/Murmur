# Agent guide: Murmur

For any agent (build, fix, review, extend) working on this repo. Murmur is a
local-first macOS text-to-speech utility: highlight text anywhere, press a
hotkey, hear it in a local Kokoro voice. No cloud, no account, no telemetry.

## What it is, and where the source lives

Two processes. Neither works without the other.

- **`app/`** — native SwiftUI menu-bar app (SwiftPM executable, not an Xcode
  project). Owns hotkey, text capture, cleanup, audio, settings, UI. Entry
  point `Sources/Murmur/MurmurApp.swift`; central state + read pipeline in
  `AppState.swift`. Module map: `docs/ARCHITECTURE.md`.
- **`backend/server.py`** — local FastAPI sidecar wrapping `kokoro-onnx`.
  Endpoints `/health`, `/voices`, `/synthesize`. Loads Kokoro once, keeps it
  warm. This is the only thing that touches the model.

**The contract between them is not a schema — it lives in the code.** Two
pieces an agent must keep in sync if touching either side:

- **Audio is raw int16 mono PCM at 24 kHz**, streamed as
  `application/octet-stream` from `/synthesize` (default, no `?format`).
  `BackendClient.streamPCM` feeds bytes to `AudioPlayer.feed`, which reinterprets
  little-endian int16 → Float32 buffers and schedules them on an
  `AVAudioPlayerNode`. Change the sample rate, channel count, or sample format on
  one side and you must change the other. `?format=wav` returns a full WAV for
  export only.
- **Backend lifecycle is reuse-first.** `BackendManager` probes `/health`; if a
  server already answers, it reuses it and never spawns one. Only if nothing
  answers does it launch `scripts/run_backend.sh`. Don't assume the app owns the
  process it's talking to.

## Where state lives (not in the repo)

- venv: `~/Library/Application Support/Murmur/venv`
- models: `~/Library/Application Support/Murmur/models` (~340 MB, downloaded at
  runtime)

Both are gitignored and machine-local. `scripts/run_backend.sh` builds the venv
on first run (uses `uv` if present, else `python3 -m venv`). Never commit
models, the venv, `.build/`, or `dist/`.

## Build, run, validate

```bash
# backend alone (auto-builds venv first run, then serves on :8765)
bash scripts/run_backend.sh

# build the app bundle and launch it
bash scripts/build_app.sh && open dist/Murmur.app

# preprocessing self-test — the only headless logic test, keep it green
cd app && swift build && "$(swift build --show-bin-path)/Murmur" --selftest

# package a release DMG
bash scripts/make_dmg.sh        # -> dist/Murmur-<version>.dmg
```

What "validated" means here, in order of confidence:

1. `swift build` (and `-c release`) compiles clean — no warnings.
2. `--selftest` prints `ALL PASS` (covers the cleanup pipeline + profiles).
3. Backend endpoints answer: `curl localhost:8765/health` reports
   `model_loaded: true`; `/synthesize` streams non-empty PCM; `?format=wav`
   produces a playable file (`ffprobe` the duration).
4. The bundled app cold-starts: wipe the venv, launch `/Applications/Murmur.app`,
   confirm it spawns its backend and `/health` goes green.

**Audio output and GUI interactions (hotkey, capture, the Settings window) can't
be verified headlessly.** State that plainly in any summary — don't claim a
read-aloud works end to end when only the byte path was checked. Capture needs
Accessibility permission and a real focused app; audio needs an output device.

## Contributing / PRs

- Branch off `main`; never commit straight to `main`. Open a PR with `gh`.
- Commit + PR style follows the user's global prefs: terse, action-first, say it
  once. End commits with `Assisted-by: Claude <model-id>` (e.g.
  `claude-opus-4-8`); omit for trivial commits (typos, version bumps).
- Keep the README ~100 lines; long design prose goes in `docs/`, not the README.
  Don't hand-maintain lists the CLI/`/voices` can print live.
- If you change the backend payload shape, update `BackendClient` and
  `AudioPlayer` together and re-run the validation list above.

## Releases

Versioned in `app/Resources/Info.plist` (`CFBundleShortVersionString`).
`make_dmg.sh` reads it for the DMG name. Cut a release with the DMG attached:

```bash
gh release create vX.Y.Z dist/Murmur-X.Y.Z.dmg --title "..." --notes "..."
# refresh an existing release's binary in place:
gh release upload vX.Y.Z dist/Murmur-X.Y.Z.dmg --clobber
```

App is ad-hoc signed, not notarized — first launch needs right-click ▸ Open.
Note that in release notes until notarization lands.

## Standing constraints

- **Fully local. No cloud TTS, no accounts, no analytics, ever.** That's the
  product. Any network call besides the one-time model download is a regression.
- Destructive shell: `trash`, never `rm -rf`/`rm -r`/`rm -f`.
- Default model IDs for any AI work: Opus `claude-opus-4-8`, Sonnet
  `claude-sonnet-4-6`, Haiku `claude-haiku-4-5-20251001`.
- macOS 14+, Apple Silicon. Prefer native APIs (AVFoundation, Carbon hotkey,
  AXUIElement) over adding dependencies.
