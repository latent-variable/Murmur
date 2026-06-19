"""Robustness + latency tests for the Murmur backend.

Run: cd backend && source <venv>/bin/activate && pip install pytest httpx
     pytest tests/ -v
Requires the model files present (skips synthesis if missing).
"""
import io
import time
import wave

import numpy as np
import pytest

from server import chunk_text, split_sentences, Engine, SAMPLE_RATE, resolve_provider
from pathlib import Path

MODELS = Path.home() / "Library/Application Support/Murmur/models"
HAVE_MODEL = (MODELS / "kokoro-v1.0.onnx").exists() and (MODELS / "voices-v1.0.bin").exists()
needs_model = pytest.mark.skipif(not HAVE_MODEL, reason="model files not installed")


@pytest.fixture(scope="session")
def engine():
    e = Engine(MODELS)
    e.load()
    assert e.kokoro is not None, e.error
    return e


# ── chunking (pure, no model) ───────────────────────────────────────────────
class TestChunking:
    def test_empty(self):
        assert chunk_text("") == []
        assert chunk_text("   \n\n  ") == []

    def test_short(self):
        assert chunk_text("Hello world.") == ["Hello world."]

    def test_paragraph_split(self):
        c = chunk_text("First para.\n\nSecond para.")
        assert len(c) == 2

    def test_abbreviations_not_split(self):
        # "Dr. Smith" must not break after "Dr."
        s = split_sentences("Dr. Smith went to Washington. He left.")
        assert len(s) == 2
        assert s[0].startswith("Dr. Smith")

    def test_long_sentence_hard_wrapped(self):
        long = "word " * 400  # ~2000 chars, no punctuation
        chunks = chunk_text(long, max_chars=320)
        assert all(len(c) <= 320 for c in chunks)
        assert len(chunks) > 1

    def test_chunk_cap_respected(self):
        text = ". ".join([f"Sentence number {i} here" for i in range(200)])
        chunks = chunk_text(text, max_chars=320)
        assert all(len(c) <= 320 for c in chunks)

    def test_no_degenerate_chunks(self):
        text = "Title\n\n```\ncode\n```\n\n---\n\nReal content here."
        chunks = chunk_text(text)
        for c in chunks:
            assert c.strip(), "empty chunk leaked"


# ── synthesis robustness ────────────────────────────────────────────────────
@needs_model
class TestSynth:
    def synth(self, engine, text, voice="af_heart", speed=1.0):
        return engine.synth(text, voice, speed, None)

    def test_short(self, engine):
        a = self.synth(engine, "Hello.")
        assert len(a) > 0

    def test_unicode_and_emoji(self, engine):
        a = self.synth(engine, "Café résumé naïve — 100% done 🎉 ✓")
        assert len(a) > 0

    def test_numbers_and_symbols(self, engine):
        a = self.synth(engine, "Order #42 cost $19.99 at 3:30pm (50% off).")
        assert len(a) > 0

    def test_urls_and_code(self, engine):
        a = self.synth(engine, "See https://github.com/x/y and run snake_case_func().")
        assert len(a) > 0

    def test_punctuation_only_does_not_crash(self, engine):
        # may be near-silent, must not raise
        a = self.synth(engine, "... --- *** ###")
        assert isinstance(a, np.ndarray)

    def test_single_word(self, engine):
        assert len(self.synth(engine, "Murmur")) > 0

    def test_dense_max_chunk(self, engine):
        # a full 320-char chunk of real words (chunk-size boundary stress)
        text = ("the quick brown fox jumps over the lazy dog " * 8)[:319] + "."
        assert len(self.synth(engine, text)) > 0

    @pytest.mark.parametrize("voice", ["af_heart", "am_michael", "bf_emma", "ef_dora"])
    def test_multiple_voices(self, engine, voice):
        assert len(self.synth(engine, "Testing this voice.", voice=voice)) > 0

    # Each non-English voice family must phonemize its own language. Regression
    # guard for the zh->cmn espeak code fix.
    @pytest.mark.parametrize("voice,text", [
        ("ef_dora", "Hola, esto es una prueba."),
        ("ff_siwis", "Bonjour, ceci est un test."),
        ("hf_alpha", "नमस्ते, यह एक परीक्षण है।"),
        ("if_sara", "Ciao, questo è un test."),
        ("jf_alpha", "こんにちは、テストです。"),
        ("pf_dora", "Olá, isto é um teste."),
        ("zf_xiaobei", "你好，这是测试。"),
        ("zm_yunjian", "你好，世界。"),
    ])
    def test_all_languages(self, engine, voice, text):
        assert len(self.synth(engine, text, voice=voice)) > 0, f"{voice} produced no audio"


# ── long-document streaming + latency (uses the chunk loop) ─────────────────
@needs_model
class TestLongDocument:
    def stream(self, engine, text):
        """Mimic /synthesize streaming: chunk, synth each, time first chunk."""
        chunks = chunk_text(text)
        t0 = time.time()
        first = None
        total = 0
        failed = 0
        for c in chunks:
            try:
                s = engine.synth(c, "af_heart", 1.0, None)
            except Exception:
                failed += 1
                continue
            if first is None:
                first = time.time() - t0
            total += len(s)
        return {"chunks": len(chunks), "first": first, "failed": failed,
                "audio_s": total / SAMPLE_RATE, "wall": time.time() - t0}

    def test_readme_sized(self, engine):
        text = (Path(__file__).parents[2] / "README.md").read_text()
        r = self.stream(engine, text)
        assert r["failed"] == 0, f"{r['failed']} chunks failed"
        assert r["first"] < 1.5, f"first chunk too slow: {r['first']:.2f}s"
        assert r["audio_s"] > 10

    def test_very_long_10x(self, engine):
        text = (Path(__file__).parents[2] / "README.md").read_text() * 10  # ~44k chars
        r = self.stream(engine, text)
        assert r["failed"] == 0, f"{r['failed']} chunks failed out of {r['chunks']}"
        assert r["first"] < 1.5, f"first chunk latency {r['first']:.2f}s"

    def test_huge_single_paragraph(self, engine):
        # 5000 chars, no paragraph breaks -> exercises sentence+hardwrap path
        text = "This is a sentence. " * 250
        r = self.stream(engine, text)
        assert r["failed"] == 0


# ── execution provider / acceleration ───────────────────────────────────────
class TestProvider:
    def test_resolve(self):
        assert resolve_provider("auto") == "CPUExecutionProvider"
        assert resolve_provider("cpu") == "CPUExecutionProvider"
        assert resolve_provider("coreml") == "CoreMLExecutionProvider"

    @needs_model
    def test_auto_loads_and_reports(self):
        e = Engine(MODELS, provider_mode="auto")
        e.load()
        assert e.kokoro is not None
        # CPU EP is always present as the implicit fallback
        assert "CPUExecutionProvider" in e.active_providers

    @needs_model
    def test_coreml_available_and_loads(self):
        # Apple Silicon should expose CoreML; loading it must not crash and must
        # keep CPU as fallback.
        e = Engine(MODELS, provider_mode="coreml")
        e.load()
        assert e.kokoro is not None, e.error
        assert "CPUExecutionProvider" in e.active_providers


# ── WAV export ──────────────────────────────────────────────────────────────
@needs_model
class TestExport:
    def test_wav_valid(self, engine):
        from server import wav_bytes
        a = engine.synth("Export check.", "af_heart", 1.0, None)
        data = wav_bytes(a)
        with wave.open(io.BytesIO(data), "rb") as w:
            assert w.getframerate() == SAMPLE_RATE
            assert w.getnchannels() == 1
            assert w.getnframes() > 0
