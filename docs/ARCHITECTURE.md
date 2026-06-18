# Architecture

Two processes. A native SwiftUI menu-bar app drives a local Python Kokoro sidecar over loopback HTTP.

## Modules

| Concern | File |
|---|---|
| App shell / scenes | `app/Sources/Murmur/MurmurApp.swift` |
| Central state + read pipeline | `AppState.swift` |
| Preferences (UserDefaults) | `Prefs.swift` |
| Global hotkey (Carbon) | `HotKey.swift` |
| Text capture (AX + clipboard) | `TextCapture.swift` |
| Accessibility permission | `Permissions.swift` |
| Preprocessing / cleanup | `Preprocess.swift` |
| Backend HTTP client | `BackendClient.swift` |
| Backend process supervisor | `BackendManager.swift` |
| Streaming audio engine | `AudioPlayer.swift` |
| Model download | `ModelDownloader.swift` |
| Launch at login | `LoginItem.swift` |
| Views | `Views/MenuContent.swift`, `Views/SettingsView.swift` |
| Logic self-test | `Selftest.swift` (`--selftest`) |
| Inference server | `backend/server.py` |

## Read pipeline

```
hotkey ⌘⇧R
  → capture (AX selected-text → clipboard fallback, clipboard restored)
  → preprocess (profile options + custom regex rules)
  → ensure backend warm
  → POST /synthesize (stream)
  → backend: chunk (paragraph → sentence, abbrev-aware) → Kokoro → int16 PCM
  → AudioPlayer: int16 → float buffers → AVAudioPlayerNode → TimePitch → mixer
```

A generation counter in `AppState` cancels a stale stream when a new read starts (configurable via "stop on new trigger").

## Audio

Raw int16 mono PCM at 24 kHz streams from the backend as `application/octet-stream`. The Swift side converts to `Float32` `AVAudioPCMBuffer`s and schedules them on an `AVAudioPlayerNode` as they arrive — playback begins on the first chunk. Pitch/volume run through `AVAudioUnitTimePitch`. Speed is applied upstream by Kokoro for better quality.

## Backend lifecycle

`BackendManager` first probes `/health`. If a backend is already running it reuses it; otherwise it spawns `scripts/run_backend.sh`, which creates the venv (in Application Support) on first run, loads Kokoro, warms it with a throwaway synthesis, and serves. The app polls health until the model reports loaded.
