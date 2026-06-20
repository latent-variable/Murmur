# TTS model watchlist

Murmur's hard constraints, in priority order:

1. **CPU-only, fast** — must run well on any Apple Silicon Mac with no GPU
   requirement (Kokoro on CPU benchmarks even-to-faster than CoreML; see AGENTS).
2. **Self-contained / ONNX** — no PyTorch/CUDA at runtime, bundles into the app.
3. **Permissive license** — Apache/MIT (this ships in a distributable app).
4. **Multiple natural English voices** out of the box. Voice cloning is a
   non-goal.

A replacement has to **beat Kokoro on quality without losing 1–3.** Most of the
2026 quality leaders lose them (they want a GPU). So far nothing dominates
Kokoro on our exact axis — like Parakeet beating Whisper, but for CPU-local TTS
that clean win doesn't exist yet. **Decision: stay on Kokoro, keep watching.**

## Current

| | |
|---|---|
| Model | **Kokoro-82M** (`kokoro-onnx`, v1.0) |
| Runtime | ONNX, CPU, ~0.2s first-audio, RTF well under 1 |
| License | Apache-2.0 (weights), model code Apache/MIT |
| Voices | 54 across 8 languages, no cloning |
| Why | Best quality-per-CPU-cost with a permissive license and many voices |

## Candidates

### Same class (CPU/ONNX — real swap options)
| Model | Size | License | vs Kokoro | Verdict |
|---|---|---|---|---|
| **Piper** | small | MIT | Faster (RTF ~0.008) but more robotic/flat | Keep as a low-latency fallback, not an upgrade |
| **Kitten TTS** | ~25 MB (int8) | Apache-2.0 | Tiny; slower than Piper, quality ≈ or < Kokoro | **Watch** — promising footprint, immature |
| **MatchaTTS** | small | MIT | CPU ONNX; quality sidegrade | Watch |

### Quality leaders that cost a GPU (break constraint #1)
| Model | License | Note | Verdict |
|---|---|---|---|
| **Chatterbox** (Resemble) | MIT | Strong quality + zero-shot cloning; realistically GPU | Revisit only if we ever add an optional GPU path |
| **Qwen3-TTS / CosyVoice 3** | Apache | Excellent, multilingual; heavier, GPU | Watch |
| **Fish Audio S2 / OpenAudio** | mixed | High quality; heavy | Watch (license per-model) |
| **F5-TTS / StyleTTS2 / XTTS-v2** | varies | Quality + cloning; GPU/heavier | Not aligned |
| **Sesame CSM** | — | Top open MOS (~4.7) but heavy | Aspirational only |

## What would make us switch

- A CPU/ONNX model with a permissive license that clearly out-naturals Kokoro at
  comparable speed, **or**
- We decide to offer an optional "GPU / higher-quality" mode — then Chatterbox or
  Qwen3-TTS become viable as a second engine (not a replacement).

## How a swap would actually work (low cost)

The backend already isolates the model behind `Engine` in `server.py`, and the
app only speaks the HTTP contract (int16 PCM stream). Adding a model =

1. New `Engine` subclass/branch that loads the candidate and implements
   `synth(text, voice, speed, lang) -> float32 ndarray @ 24 kHz`.
2. A downloader entry for its weights.
3. A provider/engine selector (like the CPU/CoreML one).

No app changes needed beyond a picker. So tracking is cheap and migrating is a
backend-local change — revisit this file when a candidate graduates from "watch."

_Last reviewed: 2026-06._
