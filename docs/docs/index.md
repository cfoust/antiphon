---
id: index
title: What is Antiphon?
slug: /
sidebar_label: What is Antiphon?
---

# What is Antiphon?

Antiphon is a spatial-audio monitor for coding agents. Every agent session you run gets a
voice and a position in a virtual room around you. Put on headphones, and instead of a wall
of terminals you get a workshop you can *overhear*: an agent reworking your auth flow murmurs
away on your left, another drafting docs hums quietly behind you, and when one finishes, it
tells you — from exactly where its work is.

The name is the point: *ἀντίφωνον* — voices, answering across a space.

## How it works

Three pieces, all in [one repository](https://github.com/cfoust/antiphon), all MIT:

- **Antiphon.app** — a native macOS app. It renders the room binaurally (real HRTF
  convolution, room acoustics, head tracking via your webcam), shows a top-down radar of your
  agents, and lets you answer them by typing — or speaking, with a voice-input tool.
- **antiphond** — a small local daemon, bundled inside the app. Agent plugins connect to it;
  it assigns each session a persona and a seat in the room, synthesizes speech (ElevenLabs,
  OpenAI, or the built-in macOS voices), and streams everything to the app. It only ever
  listens on `127.0.0.1`.
- **Plugins** — thin adapters for coding agents. [Claude Code, Codex, OpenCode, Pi, and
  Aider](./agents/index.md) are supported today, and the protocol is open — an adapter is a few
  hundred lines.

## The whole point

Antiphon is built around one interaction: **close your eyes**.

While your eyes are open, the room stays out of your way — agents are quiet presences, a
soft chord when a tool runs, a low machine hum from anyone deep in work. When you close your
eyes, the webcam notices and the room comes up around you. Turn your head toward a voice,
linger a moment, and the agent that finished tells you what it did. Open your eyes, and
you're back at your desk with a reply box waiting.

Nothing pings. Nothing flashes. A waiting agent builds a slow harmonic bloom in one ear
until you have a moment for it.

Try the feel of it in [the web demo](https://antiphon.dev/demo.html), then
[install the app](./install.md).
