---
id: opencode
title: OpenCode
---

# OpenCode

OpenCode's in-process plugin API gives this adapter high fidelity from a single
dependency-free TypeScript file: live session binding with titles, tool ticks,
model-authored narration through registered `antiphon_*` tools, an idle backstop that
speaks the last assistant message, and blocked pings from permission events.

## Install

```bash
cp plugins/opencode/index.ts ~/.config/opencode/plugins/antiphon.ts
```

That's the whole install. (Publishing as an npm package for `opencode.json`'s `plugin`
array is planned; the file works identically either way.)

## What you get

- **Bind** on `session.created` — the session takes a seat, titled from your prompt.
- **Tool ticks** on every `tool.execute.after`.
- **Narration** — the adapter registers the four `antiphon_*` tools and injects the
  narration mandate into the system prompt, so the model thinks out loud in first person.
- **Done backstop** — if the model didn't narrate, `session.idle` speaks the last
  assistant message (deduplicated against model-called `antiphon_done`).
- **Blocked** on `permission.asked`.
- **Talk-back** — messages you send from the room are delivered into the session via the
  OpenCode SDK (best-effort), with terminal-pane injection as fallback.

Subagent child sessions stay silent — only your top-level sessions get seats.
