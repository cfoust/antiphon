---
id: pi
title: Pi
---

# Pi

Pi's extension API is the most complete of the bunch — this adapter reaches full parity
with Claude Code, including genuine talk-back: messages you send from the room arrive in
the session as real user messages via `pi.sendUserMessage`.

## Install

```bash
cp plugins/pi/index.ts ~/.pi/agent/extensions/antiphon.ts
```

Hot-reloadable with `/reload`.

## What you get

- **Bind** on `session_start`, with live titles.
- **Tool ticks** on `tool_execution_start`.
- **Narration** — the adapter registers `antiphon_task` / `antiphon_progress` /
  `antiphon_done` / `antiphon_blocked` as native tools and appends the narration mandate
  to the system prompt.
- **Done backstop** — `agent_end` speaks the final assistant message when the model didn't
  narrate its own summary.
- **Talk-back, for real** — the hub's channel frames become user messages in the session,
  tagged `<channel source="antiphon">`, so you can answer an agent from the room and it
  acts on it immediately.

One limitation: Pi exposes no permission-request event to extensions, so blocked pings
only happen when the model calls `antiphon_blocked` itself.
