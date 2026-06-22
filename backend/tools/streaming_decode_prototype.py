#!/usr/bin/env python3
"""HD streaming-decode prototype — audition + stats, NOT wired into the app.

Compares two ways to turn text into HD audio with the Chatterbox Turbo model:

  baseline   model.generate(text) — one monolithic AR decode + one vocode.
             First audio only after the WHOLE utterance is done.

  streaming  fork the AR loop into a token generator; as soon as the first
             window of speech tokens is decoded, vocode it and emit audio,
             then keep decoding + vocoding the rest. Windows are vocoded
             independently (finalize=True so no phonemes are dropped) and
             joined with an equal-power crossfade.

Writes baseline.wav + streaming.wav to the out dir and prints a stats table:
time-to-first-audio, total wall time, RTF, window count. Listen to both —
the only quality question for streaming is the crossfade joins.

Run with the bundled venv python (torch lives in hd-packages):
  "$HOME/Library/Application Support/Murmur/venv/bin/python" \
      backend/tools/streaming_decode_prototype.py --voice Lino
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

import numpy as np

# backend/ on path so we can reuse the engine's loader (hd-path + mps patch).
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from chatterbox_engine import ChatterboxTurboEngine, hd_packages_dir  # noqa: E402

HD_VOICES = Path.home() / "Library/Application Support/Murmur/hd-voices"
SR = 24000
OOV = 6561          # tokens >= this are special/out-of-vocab; drop before vocode
SIL = 4299          # S3GEN_SIL — 3 of these tail the final window (matches generate())

DEFAULT_TEXT = (
    "The quick brown fox jumps over the lazy dog. "
    "Murmur reads your text aloud in a local voice, with no cloud and no account. "
    "This sentence exists to give the streaming decoder a few clauses to chew on, "
    "so we can hear whether the joins between windows are clean or seamy."
)


def stream_speech_tokens(model, text, *, temperature=0.8, top_k=1000, top_p=0.95,
                         repetition_penalty=1.2, max_gen_len=1000):
    """Fork of T3.inference_turbo that YIELDS each speech token as it decodes,
    instead of returning the whole sequence at the end. Same sampling path."""
    import torch
    import torch.nn.functional as F
    from transformers.generation.logits_process import (
        LogitsProcessorList, TemperatureLogitsWarper, TopKLogitsWarper,
        TopPLogitsWarper, RepetitionPenaltyLogitsProcessor,
    )
    from chatterbox.tts_turbo import punc_norm

    t3 = model.t3
    hp = t3.hp

    text = punc_norm(text)
    text_tokens = model.tokenizer(text, return_tensors="pt", padding=True,
                                  truncation=True).input_ids.to(model.device)

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
        t3_cond=model.conds.t3, text_tokens=text_tokens,
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


def vocode(model, toks, *, apply_fade, finalize=True):
    """Vocode a list of speech tokens -> float32 mono @ 24k. Standalone window."""
    import torch
    s3 = model.s3gen
    t = torch.tensor(toks, dtype=torch.long, device=model.device).unsqueeze(0)
    mel = s3.flow_inference(t, ref_dict=model.conds.gen, finalize=finalize,
                            n_cfm_timesteps=2)
    mel = mel.to(s3.dtype)
    wav, _ = s3.hift_inference(mel, None)
    arr = wav.squeeze(0).detach().cpu().numpy().astype(np.float32)
    if apply_fade:
        # trim_fade masks reference spillover at the very start. Only window 0
        # is a true start; later windows must NOT fade in mid-stream.
        fade = s3.trim_fade.detach().cpu().numpy().astype(np.float32)
        n = min(len(fade), len(arr))
        arr[:n] = arr[:n] * fade[:n]
    return arr


def concat_xfade(parts, n):
    """Equal-power crossfade consecutive windows over n samples."""
    parts = [p for p in parts if len(p)]
    if not parts:
        return np.zeros(0, np.float32)
    out = parts[0].astype(np.float32).copy()
    for p in parts[1:]:
        if n > 0 and len(out) >= n and len(p) >= n:
            fo = np.sqrt(np.linspace(1.0, 0.0, n, dtype=np.float32))
            fi = np.sqrt(np.linspace(0.0, 1.0, n, dtype=np.float32))
            out[-n:] = out[-n:] * fo + p[:n] * fi
            out = np.concatenate([out, p[n:]])
        else:
            out = np.concatenate([out, p])
    return out


def run_baseline(model, text):
    t0 = time.perf_counter()
    wav = model.generate(text)
    dt = time.perf_counter() - t0
    audio = wav.squeeze().detach().cpu().numpy().astype(np.float32)
    return audio, dt


def split_cost(model, text, samp):
    """Attribute total cost to AR decode vs vocode, on the full sequence."""
    import torch
    t0 = time.perf_counter()
    toks = [t for t in stream_speech_tokens(model, text, **samp) if t < OOV]
    ar = time.perf_counter() - t0
    t1 = time.perf_counter()
    _ = vocode(model, toks + [SIL, SIL, SIL], apply_fade=True, finalize=True)
    voc = time.perf_counter() - t1
    return len(toks), ar, voc


def run_streaming(model, text, *, first_size, size, xfade_ms, samp):
    t0 = time.perf_counter()
    parts, win = [], []
    target = first_size
    t_first = None
    n_full = 0  # completed full windows (excludes the trailing flush)

    for tok in stream_speech_tokens(model, text, **samp):
        if tok < OOV:
            win.append(tok)
        if len(win) >= target:
            parts.append(vocode(model, win, apply_fade=(n_full == 0), finalize=True))
            if t_first is None:
                t_first = time.perf_counter() - t0
            n_full += 1
            win = []
            target = size

    # Flush the tail with the silence pad generate() uses, finalize=True.
    final = win + [SIL, SIL, SIL]
    parts.append(vocode(model, final, apply_fade=(n_full == 0), finalize=True))
    if t_first is None:
        t_first = time.perf_counter() - t0

    total = time.perf_counter() - t0
    audio = concat_xfade(parts, int(xfade_ms * SR / 1000))
    return audio, t_first, total, len(parts)


def fmt(audio, total, t_first=None):
    sec = len(audio) / SR
    rtf = total / sec if sec else float("nan")
    ttf = f"{t_first:6.2f}s" if t_first is not None else f"{total:6.2f}s"
    return f"{ttf}   {total:6.2f}s   {sec:6.2f}s   {rtf:5.2f}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice", default=None, help="hd-voices/<name>.wav (default: first)")
    ap.add_argument("--text", default=DEFAULT_TEXT)
    ap.add_argument("--first-size", type=int, default=24, help="tokens in window 0 (~1s audio)")
    ap.add_argument("--size", type=int, default=48, help="tokens per later window (~2s)")
    ap.add_argument("--xfade-ms", type=float, default=25.0)
    ap.add_argument("--out-dir", default="/tmp/murmur_stream")
    ap.add_argument("--runs", type=int, default=1, help="repeat for variance")
    ap.add_argument("--sweep", action="store_true",
                    help="load once; try several (first,size) window configs")
    args = ap.parse_args()

    import soundfile as sf  # noqa: E402

    if args.voice:
        ref = HD_VOICES / f"{args.voice}.wav"
    else:
        refs = sorted(HD_VOICES.glob("*.wav"))
        if not refs:
            print(f"no voices in {HD_VOICES}", file=sys.stderr)
            return 2
        ref = refs[0]
    if not ref.exists():
        print(f"voice not found: {ref}", file=sys.stderr)
        return 2

    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)

    print(f"hd-packages: {hd_packages_dir()}")
    print(f"voice:       {ref.name}")
    print("loading model...")
    eng = ChatterboxTurboEngine()
    if not eng.load():
        print(f"load failed: {eng.error}", file=sys.stderr)
        return 1
    model = eng.model
    model.prepare_conditionals(str(ref))

    samp = dict(temperature=0.8, top_k=1000, top_p=0.95, repetition_penalty=1.2)

    print("warming (compile graph for this voice/shape; excluded from stats)...")
    model.generate("Warming up the decoder.")

    print(f"\ntext ({len(args.text)} chars):\n  {args.text}\n")

    if args.sweep:
        ntok, ar, voc = split_cost(model, args.text, samp)
        sec = ntok / 25.0
        print(f"cost split:  {ntok} tokens ~= {sec:.1f}s audio | "
              f"AR {ar:.2f}s (RTF {ar/sec:.2f}) | "
              f"1x vocode {voc:.2f}s (RTF {voc/sec:.2f})\n")
        print("                first-audio   total    audio    RTF")
        b_audio, b_total = run_baseline(model, args.text)
        print(f"baseline        {fmt(b_audio, b_total)}")
        for first, size in [(24, 48), (24, 96), (24, 160), (32, 240), (48, 320)]:
            s_audio, s_first, s_total, n_win = run_streaming(
                model, args.text, first_size=first, size=size,
                xfade_ms=args.xfade_ms, samp=samp)
            print(f"stream {first:>3}/{size:<4} {fmt(s_audio, s_total, s_first)}   "
                  f"({n_win} win)")
            sf.write(out / f"streaming_{first}_{size}.wav", s_audio, SR)
        sf.write(out / "baseline.wav", b_audio, SR)
        print(f"\nwrote {out}/baseline.wav + streaming_*.wav")
        return 0

    print("                first-audio   total    audio    RTF")

    for r in range(args.runs):
        tag = f" run {r+1}" if args.runs > 1 else ""
        b_audio, b_total = run_baseline(model, args.text)
        print(f"baseline{tag:>6}  {fmt(b_audio, b_total)}")
        s_audio, s_first, s_total, n_win = run_streaming(
            model, args.text, first_size=args.first_size, size=args.size,
            xfade_ms=args.xfade_ms, samp=samp)
        print(f"streaming{tag:>5}  {fmt(s_audio, s_total, s_first)}   "
              f"({n_win} windows)")
        if r == args.runs - 1:
            sf.write(out / "baseline.wav", b_audio, SR)
            sf.write(out / "streaming.wav", s_audio, SR)

    print(f"\nwrote {out}/baseline.wav and {out}/streaming.wav")
    print("Listen to both. Streaming's only quality risk is the window joins.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
