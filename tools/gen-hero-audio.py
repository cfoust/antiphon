# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy", "soundfile", "requests"]
# ///
"""Generate the marketing hero's soundtrack OFFLINE through the real engine.

Pipeline: OpenAI TTS agent lines (cached) → 48 k mono → earcons baked from the
app's exact recipes (ping/chime/drone) → a .scn timeline → `antiphon-render
scenario` (real HRTF + hall, app master/send levels) → immersion fade envelope
→ web/public/hero-demo.m4a + the RESOLVED timings the DOM animation syncs to
(web/src/site/hero-timeline.json). Timings adapt to the actual line durations,
so edit the scenario below and re-run; CI can do the same.

    OPENAI_API_KEY=... uv run tools/gen-hero-audio.py
"""

import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path

import numpy as np
import requests
import soundfile as sf

ROOT = Path(__file__).resolve().parent.parent
CACHE = ROOT / "tools/hero-cache"  # gitignored
ASSET = ROOT / "assets/baked/antiphon-kemar.antiphon"
SR = 48000

# ---- the scenario ------------------------------------------------------------
AGENTS = {
    "A": {"name": "wren", "color": "#C4694A", "bearingDeg": -35.0, "distance": 1.25, "ping": 587.33},
    "B": {"name": "sol", "color": "#7D93E8", "bearingDeg": 30.0, "distance": 1.8, "ping": 659.25},
}
VOICES = {"summary_A": "cedar", "summary_B": "marin"}
# One soundtrack per site language: spoken lines + the typed reply. Timings are
# recomputed per language from the measured TTS durations, so each language gets
# its own timeline JSON alongside its m4a.
LANGS = {
    "en": {
        "summary_A": "Rebuilt the auth flow — all forty-two tests pass. Refresh tokens rotate cleanly now.",
        "summary_B": "The docs draft is ready — two pages, with the migration notes you asked for.",
        "reply": "Ship the docs. I'll look at auth after the tests.",
    },
    "ru": {
        "summary_A": "Переделал поток авторизации — все сорок два теста проходят. Refresh-токены теперь ротируются чисто.",
        "summary_B": "Черновик документации готов — две страницы, с заметками о миграции, как ты просил.",
        "reply": "Публикуй доку. Auth посмотрю после тестов.",
    },
    "zh-Hans": {
        "summary_A": "鉴权流程重建完成——四十二个测试全部通过。刷新令牌现在能干净地轮换了。",
        "summary_B": "文档草稿好了——两页，带上你要的迁移说明。",
        "reply": "文档先发。鉴权等测试跑完我再看。",
    },
    "zh-Hant": {
        "summary_A": "驗證流程重建完成——四十二個測試全部通過。更新權杖現在能乾淨地輪換了。",
        "summary_B": "文件草稿好了——兩頁，附上你要的遷移說明。",
        "reply": "文件先出。驗證等測試跑完我再看。",
    },
}
EYES_CLOSE = 2.0     # lids begin
WORLD_IN = 2.7       # radar world fades in; audio fade 2.6→3.6
GAZE_TURN = 0.9      # head-turn duration
LINGER = 1.5         # the app's linger-to-summary
CHIME_LEAD = 0.65    # chime → summary gap (mirrors startSummary)
AFTER_A = 0.7        # breath after A's line before B pings
TYPE_CPS = 14.0      # reply typing speed (latin)
TYPE_CPS_CJK = 5.5   # hanzi land whole-word; slower feels typed, not pasted


# ---- earcons: the app's exact recipes (AudioGen.swift ports) -------------------
def make_ping(freq: float) -> np.ndarray:
    t = np.arange(int(SR * 0.6)) / SR
    env = np.exp(-t * 7.0)
    s = np.sin(2 * np.pi * freq * t) * 0.5 + np.sin(2 * np.pi * freq * 1.5 * t) * 0.22
    return (s * env).astype(np.float32)


def make_chime() -> np.ndarray:
    t = np.arange(int(SR * 0.5)) / SR
    s = np.sin(2 * np.pi * 587.33 * t) * 0.34 * np.exp(-t * 6)
    t2 = np.clip(t - 0.1, 0, None)
    s += np.where(t >= 0.1, np.sin(2 * np.pi * 880.0 * t2) * 0.34 * np.exp(-t2 * 6), 0)
    return (s * 1.3).astype(np.float32)  # CHIME_GAIN


def make_drone_segment(ping: float, dur: float) -> np.ndarray:
    """The working drone (three-tone machine hum) for `dur` seconds with the
    app's mixed level (gDrone 0.5 × baked 0.16) and gentle edge fades."""
    n = int(SR * dur)
    t = np.arange(n) / SR
    loop = 4.0
    root = round((ping / 8) * loop) / loop
    tones = [root * r for r in (1.0, 2 ** (3 / 12), 2 ** (7 / 12))]
    amps = [0.5, 0.26, 0.24]
    rates = [0.25, 0.5, 0.75]
    phases = [0.0, 2.1, 4.2]
    s = np.zeros(n)
    for k in range(3):
        roll = 0.7 + 0.3 * np.sin(2 * np.pi * rates[k] * t + phases[k])
        tone = np.sin(2 * np.pi * tones[k] * t) + 0.35 * np.sin(2 * np.pi * tones[k] * 2 * t)
        s += tone * amps[k] * roll
    s *= 0.16 * 0.5
    fade = int(SR * 1.2)
    env = np.ones(n)
    env[:fade] = np.linspace(0, 1, fade)
    env[-fade:] = np.linspace(1, 0, fade)
    return (s * env).astype(np.float32)


# ---- TTS ----------------------------------------------------------------------
def tts(voice: str, text: str) -> Path:
    key = hashlib.sha256(f"{voice}\x00{text}".encode()).hexdigest()[:16]
    out = CACHE / f"line-{key}.wav"
    if out.exists():
        return out
    r = requests.post(
        "https://api.openai.com/v1/audio/speech",
        headers={"authorization": f"Bearer {os.environ['OPENAI_API_KEY']}"},
        json={
            "model": "gpt-4o-mini-tts",
            "voice": voice,
            "input": text,
            "response_format": "wav",
            "instructions": (
                "A capable, calm coding agent reporting a finished task to its "
                "human, speaking across a quiet room. Warm, brief, done."
            ),
        },
        timeout=120,
    )
    r.raise_for_status()
    raw = CACHE / f"line-{key}-raw.wav"
    raw.write_bytes(r.content)
    # 48 k mono for the engine
    subprocess.run(
        ["afconvert", "-f", "WAVE", "-d", "LEF32@48000", "-c", "1", str(raw), str(out)],
        check=True,
    )
    raw.unlink()
    return out


def wav_dur(path: Path) -> float:
    info = sf.info(str(path))
    return info.frames / info.samplerate


def write_wav(path: Path, data: np.ndarray) -> None:
    sf.write(str(path), data, SR, subtype="FLOAT")


def build_lang(lang: str, texts: dict) -> None:
    out_audio = ROOT / f"web/public/hero-demo.{lang}.m4a"
    out_timeline = ROOT / f"web/src/site/hero-timeline.{lang}.json"
    reply = texts["reply"]
    type_cps = TYPE_CPS_CJK if lang.startswith("zh") else TYPE_CPS

    # 1) lines + measured durations
    line_paths = {k: tts(VOICES[k], texts[k]) for k in ("summary_A", "summary_B")}
    dur_a = wav_dur(line_paths["summary_A"])
    dur_b = wav_dur(line_paths["summary_B"])

    # 2) resolved timeline (times chain off real line lengths)
    gaze_a = WORLD_IN + 1.1                     # you notice A's ping, turn
    lock_a = gaze_a + GAZE_TURN + LINGER        # linger complete → chime
    line_a = lock_a + CHIME_LEAD
    ping_b = line_a + dur_a + AFTER_A           # B finishes as A wraps up
    gaze_b = ping_b + 0.5
    lock_b = gaze_b + GAZE_TURN + LINGER
    line_b = lock_b + CHIME_LEAD
    eyes_open = line_b + dur_b + 1.0
    letter_in = eyes_open + 0.6
    type_start = letter_in + 0.8
    type_end = type_start + len(reply) / type_cps
    send = type_end + 0.6
    duration = send + 1.6

    # 3) earcons
    ping_a_w = CACHE / "ping_a.wav"
    ping_b_w = CACHE / "ping_b.wav"
    chime_w = CACHE / "chime.wav"
    drone_b_w = CACHE / f"drone_b.{lang}.wav"
    write_wav(ping_a_w, make_ping(AGENTS["A"]["ping"]))
    write_wav(ping_b_w, make_ping(AGENTS["B"]["ping"]))
    write_wav(chime_w, make_chime())
    write_wav(drone_b_w, make_drone_segment(AGENTS["B"]["ping"], ping_b - WORLD_IN))

    # 4) the .scn — the app's gains: ping faced 0.9 / side 0.4, summary 0.95
    A, B = AGENTS["A"], AGENTS["B"]
    ev = []
    ev.append((drone_b_w, WORLD_IN, B, 1.0))
    ev.append((ping_a_w, WORLD_IN + 0.2, A, 0.4))       # not yet faced
    ev.append((ping_a_w, WORLD_IN + 0.2 + 2.6, A, 0.9))  # faced by now
    ev.append((chime_w, lock_a, A, 1.0))
    ev.append((line_paths["summary_A"], line_a, A, 0.95))
    ev.append((ping_b_w, ping_b, B, 0.4))
    ev.append((chime_w, lock_b, B, 1.0))
    ev.append((line_paths["summary_B"], line_b, B, 0.95))

    scn = CACHE / f"hero.{lang}.scn"
    with open(scn, "w") as f:
        f.write("room hall_conv\n")
        f.write(f"duration {duration:.2f}\nmaster 0.45\n")
        for t, yaw in [
            (0.0, 0.0),
            (gaze_a, 0.0),
            (gaze_a + GAZE_TURN, A["bearingDeg"]),
            (gaze_b, A["bearingDeg"]),
            (gaze_b + GAZE_TURN, B["bearingDeg"]),
            (eyes_open, B["bearingDeg"]),
            (eyes_open + 1.0, 0.0),
        ]:
            f.write(f"pose {t:.2f} {yaw:.1f}\n")
        for path, start, ag, gain in ev:
            f.write(
                f"event {path} {start:.2f} {ag['bearingDeg']:.1f} {ag['distance']:.2f} {gain:.2f}\n"
            )

    # 5) render through the real engine
    raw_out = CACHE / f"hero-raw.{lang}.wav"
    subprocess.run(
        ["cargo", "run", "-p", "antiphon-render", "--release", "-q", "--",
         "scenario", str(scn), str(ASSET), str(raw_out)],
        cwd=ROOT, check=True,
    )

    # 6) the immersion fade (eyes closed → world in, eyes open → out)
    audio, _ = sf.read(str(raw_out), dtype="float32")
    t = np.arange(len(audio)) / SR
    env = np.interp(t, [0, EYES_CLOSE + 0.6, WORLD_IN + 0.9, eyes_open, eyes_open + 0.9, duration],
                    [0, 0, 1, 1, 0, 0]).astype(np.float32)
    audio *= env[:, None]
    peak = float(np.abs(audio).max()) or 1.0
    audio *= min(0.891 / peak, 4.0)  # ≈ −1 dBFS
    faded = CACHE / f"hero-final.{lang}.wav"
    sf.write(str(faded), audio, SR, subtype="PCM_16")

    # 7) encode for the web
    out_audio.parent.mkdir(parents=True, exist_ok=True)
    if out_audio.exists():
        out_audio.unlink()
    subprocess.run(
        ["afconvert", "-f", "mp4f", "-d", "aac", "-b", "160000", str(faded), str(out_audio)],
        check=True,
    )

    # 8) the resolved timeline the DOM animation syncs to
    timeline = {
        "duration": round(duration, 2),
        "agents": {k: {kk: v[kk] for kk in ("name", "color", "bearingDeg", "distance")}
                   for k, v in AGENTS.items()},
        "captions": {k: texts[k] for k in ("summary_A", "summary_B")},
        "reply": reply,
        "t": {
            "eyesClose": EYES_CLOSE,
            "worldIn": WORLD_IN,
            "gazeA": round(gaze_a, 2),
            "lockA": round(lock_a, 2),
            "lineA": round(line_a, 2),
            "lineAEnd": round(line_a + dur_a, 2),
            "pingB": round(ping_b, 2),
            "gazeB": round(gaze_b, 2),
            "lockB": round(lock_b, 2),
            "lineB": round(line_b, 2),
            "lineBEnd": round(line_b + dur_b, 2),
            "eyesOpen": round(eyes_open, 2),
            "letterIn": round(letter_in, 2),
            "typeStart": round(type_start, 2),
            "typeEnd": round(type_end, 2),
            "send": round(send, 2),
        },
    }
    out_timeline.write_text(json.dumps(timeline, ensure_ascii=False, indent=2) + "\n")
    print(f"[{lang}] wrote {out_audio} ({out_audio.stat().st_size // 1024} KB), {out_timeline}")
    print(f"[{lang}] duration {duration:.1f}s  A: {dur_a:.1f}s  B: {dur_b:.1f}s")


def main() -> int:
    if "OPENAI_API_KEY" not in os.environ:
        print("OPENAI_API_KEY not set", file=sys.stderr)
        return 1
    CACHE.mkdir(parents=True, exist_ok=True)
    only = sys.argv[1] if len(sys.argv) > 1 else None
    for lang, texts in LANGS.items():
        if only and lang != only:
            continue
        build_lang(lang, texts)
    # the pre-i18n single-language outputs are superseded
    for stale in (ROOT / "web/public/hero-demo.m4a", ROOT / "web/src/site/hero-timeline.json"):
        if stale.exists():
            stale.unlink()
    return 0


if __name__ == "__main__":
    sys.exit(main())
