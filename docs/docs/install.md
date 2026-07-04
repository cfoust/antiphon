---
id: install
title: Installation
---

# Installation

Antiphon runs on macOS (Apple Silicon). The app bundles everything: the rendering engine,
the `antiphond` daemon, and the baked HRTF assets.

## Download the app

Grab the latest release:

**[Download Antiphon for macOS](https://github.com/cfoust/antiphon/releases/latest)** — grab `Antiphon-<version>-macOS.zip`.

Unzip and drag `Antiphon.app` into `/Applications`. Releases are signed and notarized
with an Apple Developer ID — it opens like any other app.

On first launch the app walks you through choosing a camera, a ten-second calibration, and
a fit adjustment for your ears. Wear headphones — the entire product is binaural.

## Connect an agent

The app renders the room; your coding agents populate it. Install the adapter for whatever
you run — [Claude Code, Codex, OpenCode, Pi, or Aider](./agents/index.md) — each is a one-liner or
a single config file. The adapters find the daemon automatically (it lives inside
`Antiphon.app`) and are fail-open: if Antiphon isn't running, your agent behaves exactly as
if the plugin weren't installed.

## Voices

Out of the box, narration uses the built-in macOS voices — free, offline, and fine. For much
better ones, open **Settings → Voices** in the app and add an
[ElevenLabs](https://elevenlabs.io) or [OpenAI](https://platform.openai.com) API key. Each
agent session is assigned a persistent voice at random from whatever providers you've
enabled; you can toggle individual voices on or off.

Keys are stored in `~/.antiphon/config.json` (mode `0600`, local only). The
`ELEVENLABS_API_KEY` and `OPENAI_API_KEY` environment variables work as fallbacks.

## Homebrew

A tap is planned (`cfoust/homebrew-taps`) but not shipped yet — for now, the zip above or
[build from source](./development.md).

## Build from source

```bash
git clone https://github.com/cfoust/antiphon
cd antiphon
cargo run -p antiphon-bake --release -- assets/baked/antiphon-default.antiphon
bash native/AntiphonApp/make.sh
open native/AntiphonApp/Antiphon.app
```

Requirements: Rust (stable), Go 1.21+, and the Xcode Command Line Tools (`swiftc`) — no
Xcode, no SwiftPM. Details in [Development](./development.md).
