---
id: privacy
title: Privacy
---

# Privacy

Antiphon is local-first. No accounts, no telemetry, no analytics — and the parts that
could be sensitive are designed to stay on your machine.

## The camera

Head tracking runs entirely on-device: the native app feeds frames to Apple's Vision
framework, the web demo to MediaPipe in your browser. Video is never recorded, stored, or
transmitted — frames are analyzed and discarded in memory. When you close Antiphon's eye
(the menu-bar toggle), the capture session stops completely and the camera indicator goes
dark.

## What can leave your machine

One thing, and only if you opt in: **speech synthesis**. If you add an ElevenLabs or
OpenAI API key in Settings → Voices, the *text* of agent narration is sent to that
provider to be turned into speech, under that provider's privacy policy. The synthesized
audio is cached locally (`~/.antiphon/tts-cache`) so repeated lines aren't re-sent. If you
stick with the built-in macOS voices, nothing leaves your machine at all.

Two small housekeeping calls also go out: the app asks GitHub's public API once a day
whether a newer release exists (a plain HTTPS request — no identifiers beyond what any
web request carries; you can turn this off in Settings → About), and the site's download
buttons do the same. That's the entire
network story.

The `antiphond` daemon listens on `127.0.0.1` only — it is never reachable from the
network. Your agent sessions' narration travels from plugin to daemon to app entirely on
localhost.

## What's on disk

Everything Antiphon stores lives in `~/.antiphon`:

- `config.json` — settings, including API keys (file mode `0600`)
- `agents.json` — the agent registry (session ids, personas, seats)
- `tts-cache/` — synthesized audio
- `antiphond.log` — the daemon's diagnostic log, truncated each run

Delete the directory and Antiphon has forgotten you — see
[Uninstall](./install.md#uninstall).

## This website

The site is static (GitHub Pages). The download buttons query GitHub's public API to find
the newest release; the web demo runs entirely in your browser and sends nothing anywhere.
