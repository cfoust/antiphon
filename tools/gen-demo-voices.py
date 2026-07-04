# /// script
# requires-python = ">=3.10"
# dependencies = ["requests"]
# ///
"""Generate the web demo's scripted-scenario voice lines via OpenAI TTS
(gpt-4o-mini-tts), one distinct voice per agent, in every site language, into
web/public/audio/demo/. Idempotent: skips files that already exist; --force
regenerates.

    OPENAI_API_KEY=... uv run tools/gen-demo-voices.py [--force] [lang]

The line texts live in web/src/demo/lines.json — the SAME file the scenario
module reads at runtime, so the agent list always shows exactly what was said.
Files: <agent>_{work,done}_<n>.<lang>.mp3.
"""

import json
import os
import sys
from pathlib import Path

import requests

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "web/public/audio/demo"
LINES = json.loads((ROOT / "web/src/demo/lines.json").read_text())
MODEL = "gpt-4o-mini-tts"

INSTRUCTIONS = (
    "A capable, calm coding agent narrating its work to its human across a "
    "quiet room. Matter-of-fact, warm, unhurried. Speak in the language of "
    "the text."
)


def tts(voice: str, text: str, out: Path) -> None:
    r = requests.post(
        "https://api.openai.com/v1/audio/speech",
        headers={"authorization": f"Bearer {os.environ['OPENAI_API_KEY']}"},
        json={
            "model": MODEL,
            "voice": voice,
            "input": text,
            "response_format": "mp3",
            "instructions": INSTRUCTIONS,
        },
        timeout=120,
    )
    r.raise_for_status()
    out.write_bytes(r.content)


def main() -> int:
    if "OPENAI_API_KEY" not in os.environ:
        print("OPENAI_API_KEY not set", file=sys.stderr)
        return 1
    force = "--force" in sys.argv
    only = next((a for a in sys.argv[1:] if not a.startswith("-")), None)
    OUT.mkdir(parents=True, exist_ok=True)

    voices: dict[str, str] = LINES["voices"]
    made = skipped = 0
    for lang, agents in LINES.items():
        if lang == "voices" or (only and lang != only):
            continue
        for agent_id, kinds in agents.items():
            for kind in ("work", "done"):
                for n, text in enumerate(kinds[kind], start=1):
                    out = OUT / f"{agent_id}_{kind}_{n}.{lang}.mp3"
                    if out.exists() and not force:
                        skipped += 1
                        continue
                    tts(voices[agent_id], text, out)
                    made += 1
                    print(f"  {out.name}")
    print(f"done: {made} generated, {skipped} already present")
    return 0


if __name__ == "__main__":
    sys.exit(main())
