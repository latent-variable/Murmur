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
import threading
from pathlib import Path
from typing import Optional

import numpy as np

log = logging.getLogger("murmur")

SAMPLE_RATE = 24000  # matches Kokoro / the PCM contract

# Streaming-decode tunables. The AR model emits speech tokens at ~25/sec of
# audio; we vocode them in windows as they decode instead of waiting for the
# whole utterance. Small first window = fast first audio; later windows amortize.
HD_STREAM_FIRST = 24   # tokens in window 0 (~1s audio)
HD_STREAM_WIN = 48     # tokens per later window (~2s)
HD_STREAM_XFADE_MS = 25
_OOV = 6561            # speech tokens >= this are special/out-of-vocab — drop
_SIL = 4299           # S3GEN_SIL — 3 pad the final window (matches generate())

# Where on-demand HD deps (torch, chatterbox-tts, ...) get installed.
def hd_packages_dir() -> Path:
    d = Path(os.environ.get("MURMUR_HD_DIR") or
             (Path.home() / "Library/Application Support/Murmur/hd-packages"))
    return d


def _ensure_path() -> None:
    p = str(hd_packages_dir())
    if p not in sys.path and Path(p).exists():
        sys.path.insert(0, p)


_mps_patched = False


def _patch_mps_float64(torch) -> None:
    """Apple's Metal backend has no float64. Chatterbox's reference-audio
    preprocessing moves float64 tensors to the GPU and crashes. Globally
    downcast float64 -> float32 on any move to mps. (Bounded to this HD process.)"""
    global _mps_patched
    if _mps_patched:
        return
    _orig_to = torch.Tensor.to

    def _safe_to(self, *a, **k):
        dev = k.get("device")
        if dev is None:
            for x in a:
                if isinstance(x, (str, torch.device)) and "mps" in str(x):
                    dev = x
                    break
        if dev is not None and "mps" in str(dev) and self.dtype == torch.float64:
            self = _orig_to(self, torch.float32)
        return _orig_to(self, *a, **k)

    torch.Tensor.to = _safe_to
    _mps_patched = True


class ChatterboxTurboEngine:
    name = "chatterbox"
    label = "Chatterbox Turbo (HD)"

    def __init__(self):
        self.model = None
        self.device = "cpu"
        self.error: Optional[str] = None
        self._cached_ref: Optional[str] = None  # voice whose conditioning is loaded
        # Serializes all model/GPU access. PyTorch/MPS is not thread-safe, and the
        # FastAPI sync endpoints run in a threadpool — so a warm (voice switch)
        # and a synth (read) can land concurrently. Without this they corrupt
        # each other on the GPU and the read's segments silently fail. A plain
        # lock suffices: load() is only ever called OUTSIDE a held lock, so no
        # locked section re-enters it.
        self._lock = threading.Lock()

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
        with self._lock:
            if self.model is not None:
                return True
            if not self.available():
                self.error = "HD engine not installed"
                return False
            try:
                _ensure_path()
                import torch
                self._install_watermarker()
                self.device = "mps" if torch.backends.mps.is_available() else "cpu"
                if self.device == "mps":
                    _patch_mps_float64(torch)  # Metal has no float64; downcast on ->mps
                from chatterbox.tts_turbo import ChatterboxTurboTTS
                log.info("loading Chatterbox Turbo on %s", self.device)
                self.model = ChatterboxTurboTTS.from_pretrained(device=self.device)
                self.error = None
                self._warmup()
                log.info("Chatterbox Turbo ready (%s)", self.device)
                return True
            except Exception as e:  # noqa: BLE001
                self.error = str(e)
                log.exception("failed to load Chatterbox Turbo")
                return False

    def _warmup(self) -> None:
        """First generate compiles the graph (~8s). Warm it with any reference
        clip so the user's first real request is fast (~RTF 0.7)."""
        try:
            refs = sorted((Path.home() / "Library/Application Support/Murmur/hd-voices").glob("*.wav"))
            if not refs or self.model is None:
                return
            self.model.generate("Ready.", audio_prompt_path=str(refs[0]))
        except Exception:  # noqa: BLE001
            pass

    def _prepare(self, ref_path: str) -> None:
        """Compute the voice conditioning once and cache it. generate() then
        reuses it instead of re-encoding the reference on every call."""
        if self._cached_ref != ref_path:
            self.model.prepare_conditionals(ref_path)
            self._cached_ref = ref_path

    def warm(self, ref_path: str) -> bool:
        """Load the model and prepare a voice so the first real read is fast."""
        if self.model is None and not self.load():
            return False
        try:
            with self._lock:   # never run concurrently with a synth on the GPU
                if ref_path and Path(ref_path).exists():
                    self._prepare(ref_path)
                    self.model.generate("Ready.")  # compile the graph for this voice
            return True
        except Exception as e:  # noqa: BLE001
            log.warning("HD warm failed: %s", e)
            return False

    def synth(self, text: str, ref_path: str, speed: float = 1.0) -> np.ndarray:
        """Clone the voice in ref_path and speak `text`. Returns float32 @ 24kHz.
        (Chatterbox has no speed knob; speed is honored by the Kokoro engine.)"""
        if self.model is None and not self.load():
            raise RuntimeError(self.error or "HD engine not loaded")
        if not ref_path or not Path(ref_path).exists():
            raise RuntimeError("reference voice clip missing")
        with self._lock:   # serialize GPU access — warm/synth must not overlap
            self._prepare(ref_path)             # cached; cheap after first call
            wav = self.model.generate(text)     # reuse cached conditioning
            # MPS ops are async; keep the GPU->CPU transfer inside the lock so it
            # can't read the tensor while another thread runs generate().
            arr = wav.squeeze().detach().cpu().numpy().astype(np.float32)
        return arr

    # ---- streaming decode (experimental) -------------------------------

    def _ar_tokens(self, text, temperature=0.8, top_k=1000, top_p=0.95,
                   repetition_penalty=1.2, max_gen_len=1000):
        """Yield speech tokens as the AR model decodes them. Fork of
        T3.inference_turbo that yields each token instead of returning the
        whole sequence — lets us vocode early windows before decode finishes."""
        import torch
        import torch.nn.functional as F
        from transformers.generation.logits_process import (
            LogitsProcessorList, TemperatureLogitsWarper, TopKLogitsWarper,
            TopPLogitsWarper, RepetitionPenaltyLogitsProcessor,
        )
        from chatterbox.tts_turbo import punc_norm

        m = self.model
        t3 = m.t3
        hp = t3.hp

        text = punc_norm(text)
        text_tokens = m.tokenizer(text, return_tensors="pt", padding=True,
                                  truncation=True).input_ids.to(m.device)

        procs = LogitsProcessorList()
        if temperature > 0 and temperature != 1.0:
            procs.append(TemperatureLogitsWarper(temperature))
        if top_k > 0:
            procs.append(TopKLogitsWarper(top_k))
        if top_p < 1.0:
            procs.append(TopPLogitsWarper(top_p))
        if repetition_penalty != 1.0:
            procs.append(RepetitionPenaltyLogitsProcessor(repetition_penalty))

        speech_start = hp.start_speech_token * torch.ones_like(text_tokens[:, :1])
        embeds, _ = t3.prepare_input_embeds(
            t3_cond=m.conds.t3, text_tokens=text_tokens,
            speech_tokens=speech_start, cfg_weight=0.0,
        )

        gen = []
        out = t3.tfmr(inputs_embeds=embeds, use_cache=True)
        hidden = out[0]
        past = out.past_key_values
        logits = t3.speech_head(hidden[:, -1:])
        proc = procs(speech_start, logits[:, -1, :])
        nxt = torch.multinomial(F.softmax(proc, dim=-1), num_samples=1)
        gen.append(nxt)
        cur = nxt
        if int(nxt) == hp.stop_speech_token:
            return
        yield int(nxt)

        for _ in range(max_gen_len):
            emb = t3.speech_emb(cur)
            out = t3.tfmr(inputs_embeds=emb, past_key_values=past, use_cache=True)
            hidden = out[0]
            past = out.past_key_values
            logits = t3.speech_head(hidden)
            ids = torch.cat(gen, dim=1)
            proc = procs(ids, logits[:, -1, :])
            if torch.all(proc == -float("inf")):
                break
            nxt = torch.multinomial(F.softmax(proc, dim=-1), num_samples=1)
            gen.append(nxt)
            cur = nxt
            tok = int(nxt)
            if tok == hp.stop_speech_token:
                break
            yield tok

    def _vocode_window(self, toks: list, apply_fade: bool) -> np.ndarray:
        """Vocode one window of speech tokens -> float32 @ 24k. Standalone
        (finalize=True, no lookahead drop), watermarked like generate()."""
        import torch
        m = self.model
        s3 = m.s3gen
        t = torch.tensor(toks, dtype=torch.long, device=m.device).unsqueeze(0)
        mel = s3.flow_inference(t, ref_dict=m.conds.gen, finalize=True,
                                n_cfm_timesteps=2).to(s3.dtype)
        wav, _ = s3.hift_inference(mel, None)
        arr = wav.squeeze(0).detach().cpu().numpy().astype(np.float32)
        if apply_fade:
            # trim_fade masks reference spillover at the very start. Only the
            # first window is a true start; later windows must not fade in.
            fade = s3.trim_fade.detach().cpu().numpy().astype(np.float32)
            n = min(len(fade), len(arr))
            arr[:n] = arr[:n] * fade[:n]
        # Keep the watermark guarantee generate() provides — the direct
        # flow/hift path skips it, so apply it here per window.
        arr = m.watermarker.apply_watermark(arr, sample_rate=SAMPLE_RATE)
        return np.asarray(arr, dtype=np.float32)

    def _iter_window_audio(self, text, first, size):
        """Decode tokens and vocode them in windows; yield each window's audio."""
        win: list = []
        target = first
        first_win = True
        for tok in self._ar_tokens(text):
            if tok < _OOV:
                win.append(tok)
            if len(win) >= target:
                yield self._vocode_window(win, apply_fade=first_win)
                first_win = False
                win = []
                target = size
        yield self._vocode_window(win + [_SIL, _SIL, _SIL], apply_fade=first_win)

    def synth_stream(self, text: str, ref_path: str,
                     first: int = HD_STREAM_FIRST, size: int = HD_STREAM_WIN,
                     xfade_ms: float = HD_STREAM_XFADE_MS):
        """Streaming variant of synth(): yields float32 @ 24k audio windows as
        the model decodes, equal-power crossfaded at the joins. The yielded
        chunks are already contiguous (the crossfade overlap is handled here via
        a carry buffer), so the consumer can append them gap-free."""
        if self.model is None and not self.load():
            raise RuntimeError(self.error or "HD engine not loaded")
        if not ref_path or not Path(ref_path).exists():
            raise RuntimeError("reference voice clip missing")
        n_xf = int(xfade_ms * SAMPLE_RATE / 1000)
        with self._lock:   # serialize GPU access for the whole stream
            self._prepare(ref_path)
            carry: Optional[np.ndarray] = None
            for win_audio in self._iter_window_audio(text, first, size):
                if carry is None:
                    if n_xf > 0 and len(win_audio) > n_xf:
                        yield win_audio[:-n_xf].copy()
                        carry = win_audio[-n_xf:].copy()
                    else:
                        carry = win_audio
                    continue
                if n_xf > 0 and len(win_audio) >= n_xf and len(carry) == n_xf:
                    fo = np.sqrt(np.linspace(1.0, 0.0, n_xf, dtype=np.float32))
                    fi = np.sqrt(np.linspace(0.0, 1.0, n_xf, dtype=np.float32))
                    mixed = carry * fo + win_audio[:n_xf] * fi
                    rest = win_audio[n_xf:]
                    if len(rest) > n_xf:
                        yield np.concatenate([mixed, rest[:-n_xf]])
                        carry = rest[-n_xf:].copy()
                    else:
                        yield mixed
                        carry = rest.copy() if len(rest) else None
                else:
                    # window too short to crossfade — flush carry, append plain
                    yield carry
                    carry = win_audio
            if carry is not None and len(carry):
                yield carry

    def status(self) -> dict:
        return {
            "name": self.name,
            "label": self.label,
            "installed": self.available(),
            "loaded": self.model is not None,
            "device": self.device,
            "error": self.error,
        }
