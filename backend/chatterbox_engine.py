"""Chatterbox Turbo engine — optional "HD" voice cloning.

Heavy (PyTorch). Lazy: nothing here imports torch until the engine actually
loads, so the default Kokoro path stays light. Deps live in a separate
app-support directory (installed on demand), not the signed app bundle.

Chatterbox Turbo is cloning-only: it needs a ~10s reference clip per voice.
"""
from __future__ import annotations

import logging
import os
import sys
from pathlib import Path
from typing import Optional

import numpy as np

log = logging.getLogger("murmur")

SAMPLE_RATE = 24000  # matches Kokoro / the PCM contract

# Where on-demand HD deps (torch, chatterbox-tts, ...) get installed.
def hd_packages_dir() -> Path:
    d = Path(os.environ.get("MURMUR_HD_DIR") or
             (Path.home() / "Library/Application Support/Murmur/hd-packages"))
    return d


def _ensure_path() -> None:
    p = str(hd_packages_dir())
    if p not in sys.path and Path(p).exists():
        sys.path.insert(0, p)


class ChatterboxTurboEngine:
    name = "chatterbox"
    label = "Chatterbox Turbo (HD)"

    def __init__(self):
        self.model = None
        self.device = "cpu"
        self.error: Optional[str] = None

    def available(self) -> bool:
        """Are the heavy deps importable (without loading the model)?"""
        _ensure_path()
        import importlib.util
        return all(importlib.util.find_spec(m) is not None
                   for m in ("torch", "chatterbox"))

    def _install_watermarker(self):
        """Chatterbox requires a perth watermarker instance. Use the real one
        when present; otherwise a pass-through so HD mode still runs (logged)."""
        try:
            import perth
            if getattr(perth, "PerthImplicitWatermarker", None) is not None:
                return  # real watermarker available
        except Exception:  # noqa: BLE001
            import types
            perth = types.ModuleType("perth")
            sys.modules["perth"] = perth
        log.warning("perth watermarker unavailable — HD audio will NOT be watermarked")

        class _PassThrough:
            def apply_watermark(self, wav, sample_rate=None, **k):
                return wav

            def get_watermark(self, *a, **k):
                return None

        perth.PerthImplicitWatermarker = _PassThrough  # type: ignore[attr-defined]

    def load(self) -> bool:
        if self.model is not None:
            return True
        if not self.available():
            self.error = "HD engine not installed"
            return False
        try:
            _ensure_path()
            import torch
            self._install_watermarker()
            from chatterbox.tts_turbo import ChatterboxTurboTTS
            self.device = "mps" if torch.backends.mps.is_available() else "cpu"
            log.info("loading Chatterbox Turbo on %s", self.device)
            self.model = ChatterboxTurboTTS.from_pretrained(device=self.device)
            self.error = None
            log.info("Chatterbox Turbo ready (%s)", self.device)
            return True
        except Exception as e:  # noqa: BLE001
            self.error = str(e)
            log.exception("failed to load Chatterbox Turbo")
            return False

    def synth(self, text: str, ref_path: str, speed: float = 1.0) -> np.ndarray:
        """Clone the voice in ref_path and speak `text`. Returns float32 @ 24kHz.
        (Chatterbox has no speed knob; speed is honored by the Kokoro engine.)"""
        if self.model is None and not self.load():
            raise RuntimeError(self.error or "HD engine not loaded")
        if not ref_path or not Path(ref_path).exists():
            raise RuntimeError("reference voice clip missing")
        wav = self.model.generate(text, audio_prompt_path=ref_path)
        arr = wav.squeeze().detach().cpu().numpy().astype(np.float32)
        return arr

    def status(self) -> dict:
        return {
            "name": self.name,
            "label": self.label,
            "installed": self.available(),
            "loaded": self.model is not None,
            "device": self.device,
            "error": self.error,
        }
