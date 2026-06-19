"""Murmur Kokoro TTS backend.

Local FastAPI sidecar. Loads Kokoro once, keeps it warm, streams raw PCM for
low-latency playback. No cloud, no telemetry.

Endpoints:
  GET  /health                -> readiness + model status
  GET  /voices                -> available voices grouped by language
  GET  /models                -> model file status in models dir
  POST /synthesize            -> stream raw int16 PCM mono (X-Sample-Rate header)
  POST /synthesize?format=wav -> full WAV blob (for export)
"""
from __future__ import annotations

import argparse
import io
import logging
import os
import re
import sys
import wave
from pathlib import Path
from typing import Iterator, Optional

import numpy as np
from fastapi import FastAPI, HTTPException, Query
from fastapi.responses import Response, StreamingResponse
from pydantic import BaseModel

logging.basicConfig(level=logging.INFO, format="%(asctime)s murmur %(levelname)s %(message)s")
log = logging.getLogger("murmur")

SAMPLE_RATE = 24000  # Kokoro native

# Language code per voice prefix (first two chars of voice name).
LANG_BY_PREFIX = {
    "af": "en-us", "am": "en-us",
    "bf": "en-gb", "bm": "en-gb",
    "ef": "es", "em": "es",
    "ff": "fr-fr",
    "hf": "hi", "hm": "hi",
    "if": "it", "im": "it",
    "jf": "ja", "jm": "ja",
    "pf": "pt-br", "pm": "pt-br",
    "zf": "zh", "zm": "zh",
}
LANG_LABEL = {
    "en-us": "English (US)", "en-gb": "English (UK)", "es": "Spanish",
    "fr-fr": "French", "hi": "Hindi", "it": "Italian", "ja": "Japanese",
    "pt-br": "Portuguese (BR)", "zh": "Chinese",
}


def lang_for_voice(voice: str) -> str:
    return LANG_BY_PREFIX.get(voice[:2], "en-us")


# --- sentence-ish chunking, abbreviation aware ----------------------------------
_ABBREV = {
    "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "etc", "e.g", "i.e",
    "fig", "inc", "ltd", "co", "no", "vol", "approx", "dept", "univ", "min", "max",
}
_SENT_END = re.compile(r"([.!?]+[\"')\]]?)(\s+)")


def split_sentences(text: str) -> list[str]:
    text = text.strip()
    if not text:
        return []
    out: list[str] = []
    parts = _SENT_END.split(text)
    # parts: [chunk, punct, space, chunk, punct, space, ...]
    buf = ""
    i = 0
    while i < len(parts):
        buf += parts[i]
        if i + 1 < len(parts):
            punct = parts[i + 1]
            buf += punct
            last_word = re.split(r"\s+", buf.strip())[-1].rstrip(".!?\"')]").lower()
            if last_word in _ABBREV:
                buf += parts[i + 2] if i + 2 < len(parts) else ""
                i += 3
                continue
            out.append(buf.strip())
            buf = ""
            i += 3
        else:
            i += 1
    if buf.strip():
        out.append(buf.strip())
    return out


def chunk_text(text: str, max_chars: int = 320) -> list[str]:
    """Paragraphs -> sentences -> length-capped chunks."""
    chunks: list[str] = []
    for para in re.split(r"\n\s*\n", text):
        para = para.strip()
        if not para:
            continue
        cur = ""
        for sent in split_sentences(para) or [para]:
            if len(sent) > max_chars:
                # hard wrap an over-long sentence on word boundaries
                if cur:
                    chunks.append(cur); cur = ""
                words = sent.split(" ")
                line = ""
                for w in words:
                    if len(line) + len(w) + 1 > max_chars:
                        chunks.append(line.strip()); line = w
                    else:
                        line = f"{line} {w}".strip()
                if line:
                    chunks.append(line.strip())
            elif len(cur) + len(sent) + 1 > max_chars:
                chunks.append(cur); cur = sent
            else:
                cur = f"{cur} {sent}".strip()
        if cur:
            chunks.append(cur)
    return chunks


# --- engine ---------------------------------------------------------------------
# onnxruntime execution-provider selection. CoreML routes to Apple GPU/ANE,
# but for an 82M model like Kokoro it benchmarks ~even-to-slower than the
# vectorized CPU EP (most ops fall back to CPU). So "auto" picks CPU; users can
# force CoreML. CPU is always appended as the implicit fallback either way.
PROVIDER_ALIASES = {
    "cpu": "CPUExecutionProvider",
    "coreml": "CoreMLExecutionProvider",
}


def resolve_provider(mode: str) -> str:
    mode = (mode or "auto").lower()
    if mode == "auto":
        return "CPUExecutionProvider"
    return PROVIDER_ALIASES.get(mode, mode)


class Engine:
    def __init__(self, models_dir: Path, provider_mode: str = "auto"):
        self.models_dir = models_dir
        self.kokoro = None
        self.model_path = models_dir / "kokoro-v1.0.onnx"
        self.voices_path = models_dir / "voices-v1.0.bin"
        self.error: Optional[str] = None
        self.provider_mode = provider_mode
        self.active_providers: list[str] = []

    def files_present(self) -> bool:
        return self.model_path.exists() and self.voices_path.exists()

    def load(self) -> None:
        if self.kokoro is not None:
            return
        if not self.files_present():
            self.error = "model files missing"
            return
        chosen = resolve_provider(self.provider_mode)
        if self._try_load(chosen):
            return
        # fall back to CPU if the requested provider failed to build a session
        if chosen != "CPUExecutionProvider":
            log.warning("provider %s failed, falling back to CPU", chosen)
            self._try_load("CPUExecutionProvider")

    def _try_load(self, provider: str) -> bool:
        try:
            from kokoro_onnx import Kokoro
            os.environ["ONNX_PROVIDER"] = provider  # kokoro-onnx reads this
            log.info("loading Kokoro from %s (provider=%s)", self.models_dir, provider)
            kokoro = Kokoro(str(self.model_path), str(self.voices_path))
            kokoro.create("Ready.", voice="af_heart", speed=1.0, lang="en-us")  # warm
            self.kokoro = kokoro
            self.active_providers = list(kokoro.sess.get_providers())
            self.error = None
            log.info("Kokoro warm on %s, %d voices", self.active_providers, len(kokoro.get_voices()))
            return True
        except Exception as e:  # noqa: BLE001
            self.error = str(e)
            log.exception("failed to load Kokoro on %s", provider)
            return False

    def available_providers(self) -> list[str]:
        try:
            import onnxruntime as ort
            return list(ort.get_available_providers())
        except Exception:  # noqa: BLE001
            return []

    def voices(self) -> list[str]:
        if self.kokoro is None:
            return []
        return sorted(self.kokoro.get_voices())

    def synth(self, text: str, voice: str, speed: float, lang: Optional[str]) -> np.ndarray:
        if self.kokoro is None:
            self.load()
        if self.kokoro is None:
            raise RuntimeError(self.error or "engine not loaded")
        lang = lang or lang_for_voice(voice)
        samples, _sr = self.kokoro.create(text, voice=voice, speed=speed, lang=lang)
        return np.asarray(samples, dtype=np.float32)


def pcm16(samples: np.ndarray) -> bytes:
    clipped = np.clip(samples, -1.0, 1.0)
    return (clipped * 32767.0).astype("<i2").tobytes()


def wav_bytes(samples: np.ndarray) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SAMPLE_RATE)
        w.writeframes(pcm16(samples))
    return buf.getvalue()


# --- app ------------------------------------------------------------------------
engine: Engine  # set in main


class SynthReq(BaseModel):
    text: str
    voice: str = "af_heart"
    speed: float = 1.0
    lang: Optional[str] = None


app = FastAPI(title="Murmur TTS", docs_url=None, redoc_url=None)


@app.get("/health")
def health():
    return {
        "status": "ok",
        "model_loaded": engine.kokoro is not None,
        "files_present": engine.files_present(),
        "models_dir": str(engine.models_dir),
        "error": engine.error,
        "sample_rate": SAMPLE_RATE,
        "provider_mode": engine.provider_mode,
        "active_providers": engine.active_providers,
        "available_providers": engine.available_providers(),
    }


@app.get("/voices")
def voices():
    items = []
    for v in engine.voices():
        lang = lang_for_voice(v)
        gender = "female" if v[1] == "f" else "male"
        items.append({
            "id": v,
            "lang": lang,
            "lang_label": LANG_LABEL.get(lang, lang),
            "gender": gender,
        })
    return {"voices": items, "count": len(items)}


@app.get("/models")
def models():
    return {
        "models_dir": str(engine.models_dir),
        "model_file": {"name": engine.model_path.name, "present": engine.model_path.exists(),
                       "bytes": engine.model_path.stat().st_size if engine.model_path.exists() else 0},
        "voices_file": {"name": engine.voices_path.name, "present": engine.voices_path.exists(),
                        "bytes": engine.voices_path.stat().st_size if engine.voices_path.exists() else 0},
    }


@app.post("/synthesize")
def synthesize(req: SynthReq, format: str = Query("pcm")):
    if not req.text.strip():
        raise HTTPException(400, "empty text")
    if engine.kokoro is None:
        engine.load()
    if engine.kokoro is None:
        raise HTTPException(503, engine.error or "engine not loaded")

    chunks = chunk_text(req.text)
    if not chunks:
        raise HTTPException(400, "no speakable text")

    if format == "wav":
        pieces = [engine.synth(c, req.voice, req.speed, req.lang) for c in chunks]
        gap = np.zeros(int(SAMPLE_RATE * 0.12), dtype=np.float32)
        joined = np.concatenate([p for c in pieces for p in (c, gap)]) if pieces else np.zeros(0, np.float32)
        data = wav_bytes(joined)
        return Response(content=data, media_type="audio/wav",
                        headers={"Content-Disposition": "attachment; filename=murmur.wav"})

    def gen() -> Iterator[bytes]:
        for i, c in enumerate(chunks):
            try:
                samples = engine.synth(c, req.voice, req.speed, req.lang)
            except Exception as e:  # noqa: BLE001
                log.error("synth chunk %d failed: %s", i, e)
                continue
            yield pcm16(samples)
            # short silence between chunks for natural pacing
            yield pcm16(np.zeros(int(SAMPLE_RATE * 0.1), dtype=np.float32))

    return StreamingResponse(gen(), media_type="application/octet-stream",
                             headers={"X-Sample-Rate": str(SAMPLE_RATE),
                                      "X-Chunks": str(len(chunks))})


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=8765)
    default_models = os.environ.get("MURMUR_MODELS_DIR") or str(
        Path.home() / "Library/Application Support/Murmur/models")
    p.add_argument("--models-dir", default=default_models)
    p.add_argument("--provider", default=os.environ.get("MURMUR_PROVIDER", "auto"),
                   help="auto | cpu | coreml")
    p.add_argument("--no-preload", action="store_true")
    args = p.parse_args()

    global engine
    mdir = Path(args.models_dir).expanduser()
    mdir.mkdir(parents=True, exist_ok=True)
    engine = Engine(mdir, provider_mode=args.provider)
    if not args.no_preload:
        engine.load()

    import uvicorn
    log.info("serving on http://%s:%d (models: %s)", args.host, args.port, mdir)
    uvicorn.run(app, host=args.host, port=args.port, log_level="warning")


if __name__ == "__main__":
    sys.exit(main())
