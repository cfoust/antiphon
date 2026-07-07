# /// script
# requires-python = ">=3.10"
# dependencies = ["requests"]
# ///
"""Generate the onboarding voice lines (calibration cues + fit loop) in every
UI language via OpenAI TTS (gpt-4o-mini-tts), into the app's bundled
resources. Idempotent: skips files that already exist; --force regenerates.

    OPENAI_API_KEY=... uv run tools/gen-onboarding-voices.py [--force]

The voice is AI-generated (gpt-4o-mini-tts "marin") — the app's intro
already discloses that agent voices are synthetic.
"""

import os
import sys
from pathlib import Path

import requests

OUT = Path(__file__).resolve().parent.parent / "native/AntiphonApp/Resources/onboarding"
MODEL = "gpt-4o-mini-tts"
VOICE = "marin"  # recommended quality tier; falls back to coral if unavailable

# key -> lang -> input text. Keep these in sync with the UI copy in L10n.swift.
LINES = {
    "cal_left": {
        "en": "Turn your head all the way to the left… and hold still.",
        "ru": "Поверните голову до упора влево… и замрите.",
        "zh-Hans": "把头一直转到最左边……保持不动。",
        "zh-Hant": "把頭一直轉到最左邊……保持不動。",
    },
    "cal_right": {
        "en": "Now all the way to the right… and hold still.",
        "ru": "Теперь до упора вправо… и замрите.",
        "zh-Hans": "现在转到最右边……保持不动。",
        "zh-Hant": "現在轉到最右邊……保持不動。",
    },
    "cal_done": {
        "en": "Done. You're calibrated.",
        "ru": "Готово. Калибровка завершена.",
        "zh-Hans": "好了，校准完成。",
        "zh-Hant": "好了，校準完成。",
    },
    "fit": {
        "en": "Move the slider until my voice sits just ahead of you, out in the room.",
        "ru": "Двигайте ползунок, пока мой голос не окажется прямо перед вами, в глубине комнаты.",
        "zh-Hans": "移动滑块，直到我的声音悬在你正前方的空间里。",
        "zh-Hant": "移動滑塊，直到我的聲音懸在你正前方的空間裡。",
    },
    "close_eyes": {
        "en": "Close your eyes — the room comes alive when you do.",
        "ru": "Закройте глаза — комната оживает, когда вы это делаете.",
        "zh-Hans": "闭上眼睛——当你闭眼时，房间便活了过来。",
        "zh-Hant": "閉上眼睛——當你閉眼時，房間便活了過來。",
    },
}

TONE = {
    "en": "English",
    "ru": "Russian",
    "zh-Hans": "Mandarin Chinese (Simplified script)",
    "zh-Hant": "Mandarin Chinese (Traditional script)",
}


def synth(text: str, lang: str, voice: str, key: str) -> bytes:
    r = requests.post(
        "https://api.openai.com/v1/audio/speech",
        headers={"authorization": f"Bearer {os.environ['OPENAI_API_KEY']}"},
        json={
            "model": MODEL,
            "voice": voice,
            "input": text,
            "response_format": "mp3",
            "instructions": (
                f"Speak in {TONE[lang]}. Calm, warm, unhurried — a gentle guide "
                "leading someone through a first-time setup with their eyes on a screen. "
                "Soft, close, low-key; never salesy."
            ),
        },
        timeout=60,
    )
    r.raise_for_status()
    return r.content


def main() -> int:
    force = "--force" in sys.argv
    if "OPENAI_API_KEY" not in os.environ:
        print("OPENAI_API_KEY not set", file=sys.stderr)
        return 1
    OUT.mkdir(parents=True, exist_ok=True)
    voice = VOICE
    for key, langs in LINES.items():
        for lang, text in langs.items():
            path = OUT / f"{key}_{lang}.mp3"
            if path.exists() and not force:
                print(f"  = {path.name} (exists)")
                continue
            try:
                audio = synth(text, lang, voice, key)
            except requests.HTTPError as e:
                if voice != "coral" and e.response is not None and e.response.status_code == 400:
                    print(f"  ! voice {voice} rejected, falling back to coral")
                    voice = "coral"
                    audio = synth(text, lang, voice, key)
                else:
                    raise
            path.write_bytes(audio)
            print(f"  + {path.name} ({len(audio) // 1024} KB, {voice})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
