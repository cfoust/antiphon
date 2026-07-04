# /// script
# requires-python = ">=3.10"
# dependencies = ["requests"]
# ///
"""Generate the web demo's scripted-scenario voice lines via OpenAI TTS
(gpt-4o-mini-tts), one distinct voice per agent, into web/public/audio/demo/.
Idempotent: skips files that already exist; --force regenerates.

    OPENAI_API_KEY=... uv run tools/gen-demo-voices.py [--force]

Files: <agent>_done_<n>.mp3 (spoken task summaries, played when you face a
finished agent) and <agent>_work_<n>.mp3 (short working murmurs, occasional
narration while the agent works). The line TEXT is mirrored in
web/src/demo/scenario.ts so the agent list can show what was said — keep the
two in sync.
"""

import os
import sys
from pathlib import Path

import requests

OUT = Path(__file__).resolve().parent.parent / "web/public/audio/demo"
MODEL = "gpt-4o-mini-tts"

# agent id -> (voice, {kind_n: line}). Voices are distinct per agent so the
# room reads as different people. Keep texts in sync with scenario.ts.
AGENTS: dict[str, tuple[str, dict[str, str]]] = {
    "atlas": (
        "onyx",
        {
            "work_1": "Tracing every call site of the old session middleware.",
            "work_2": "Rewriting the token refresh path now.",
            "done_1": "The auth refactor is in. Sessions refresh tokens in one place now, and the old middleware is gone.",
            "done_2": "I split the login flow out of the monolith. Twelve files touched, all tests green.",
            "done_3": "Password reset goes through the same token service now. I removed about four hundred lines.",
        },
    ),
    "wren": (
        "marin",
        {
            "work_1": "Backfilling the new columns in batches.",
            "work_2": "Dry-running the migration against a staging snapshot.",
            "done_1": "The migration ran clean. Both tables are on the new schema, and the backfill finished in under a minute.",
            "done_2": "I split the migration into three reversible steps. Staging is migrated; production is ready when you are.",
            "done_3": "Indexes are rebuilt and the slow query is gone. Reads are about six times faster.",
        },
    ),
    "cass": (
        "cedar",
        {
            "work_1": "Running the integration suite again to reproduce it.",
            "work_2": "Bisecting the test order to find the leak.",
            "done_1": "Found the flake. A shared fixture leaked a timer between tests; it's isolated now, and the suite passed ten runs in a row.",
            "done_2": "The race was in the websocket teardown. I made close idempotent and the suite is stable again.",
            "done_3": "Two flaky tests were sharing a temp directory. They each get their own now, and CI is green.",
        },
    ),
    "iris": (
        "coral",
        {
            "work_1": "Reading the changelog for breaking changes.",
            "work_2": "Bumping the lockfile and rebuilding.",
            "done_1": "The dependency upgrade is done. Two breaking changes patched, and the bundle came out smaller.",
            "done_2": "Everything is on the latest major now. I pinned the one package that broke and left a note about it.",
            "done_3": "Docs are updated to match the new API. Every example compiles again.",
        },
    ),
}

INSTRUCTIONS = (
    "First person, calm and quiet — a focused software agent reporting to a "
    "colleague sitting nearby. Matter-of-fact and a little warm; unhurried, "
    "low-key, never salesy. Working lines are murmured half to yourself; "
    "done lines are a clear, brief report."
)


def synth(text: str, voice: str) -> bytes:
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
    for agent, (voice, lines) in AGENTS.items():
        for key, text in lines.items():
            path = OUT / f"{agent}_{key}.mp3"
            if path.exists() and not force:
                print(f"  = {path.name} (exists)")
                continue
            try:
                audio = synth(text, voice)
            except requests.HTTPError as e:
                # marin/cedar are the newer quality-tier voices; fall back per-call
                if e.response is not None and e.response.status_code == 400 and voice not in ("coral", "onyx"):
                    print(f"  ! voice {voice} rejected, falling back to coral")
                    voice = "coral"
                    audio = synth(text, voice)
                else:
                    raise
            path.write_bytes(audio)
            print(f"  + {path.name} ({len(audio) // 1024} KB, {voice})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
