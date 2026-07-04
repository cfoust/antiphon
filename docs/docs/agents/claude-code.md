---
id: claude-code
title: Claude Code
---

# Claude Code

The reference integration, and the highest-fidelity one: identity binding, tool ticks,
LLM-authored narration, spoken summaries, blocked notifications, and talk-back from the
room into the session.

## Install

```bash
claude plugin marketplace add cfoust/antiphon
claude plugin install antiphon@antiphon
```

That's it. The plugin locates `antiphond` automatically (it's bundled inside
`Antiphon.app`) and starts narrating on your next session.

## How it works

- An MCP server (`antiphond channel`) gives the model four tools — `antiphon_task`,
  `antiphon_progress`, `antiphon_done`, `antiphon_blocked` — and a session-start hook
  injects a short mandate telling it to think out loud through them. The narration you
  hear is authored by the model as it works.
- A `PostToolUse` hook emits a fire-and-forget tick per tool call — that's the chord.
- Messages you send from the room arrive in the session as user input.

## Developing against a checkout

```bash
claude --plugin-dir /path/to/antiphon/plugins/claude-code
```

Set `ANTIPHOND` to point at a specific daemon binary if you're hacking on the daemon
itself.
