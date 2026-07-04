# plugins/pi — Pi extension for Antiphon

Narrates Pi (badlogic/pi-mono `coding-agent`) sessions into the Antiphon
spatial-audio monitor via `antiphond` (see `docs/agent-bridge.md`). Runs
in-process with a persistent `/agent` WebSocket — the same full-fidelity rung
as the Claude Code plugin, plus genuine bidirectional talk-back.

## What it does

- **Bind**: `session_start` (and eagerly at load) → identity hello
  (`kind: pi`, repo, cwd, tmux/cy input target). Session id is
  `$ANTIPHON_SESSION` or derived from pi's pid + cwd hash (stable across
  `/reload`).
- **Tool ticks**: `tool_execution_start` → `{type:"tool"}` blip (chord tick);
  our own `antiphon_*` calls don't tick.
- **Narration tools**: `pi.registerTool` × 4 — `antiphon_task` /
  `antiphon_progress` / `antiphon_done` / `antiphon_blocked`; the narration
  mandate is appended to the system prompt in `before_agent_start`.
- **Done backstop**: `agent_end` → spoken done from the final assistant
  message, skipped when the model already called `antiphon_done` in the last
  30 s.
- **Talk-back (real)**: hub `{type:"channel"}` frames (the user speaking from
  the room) become `pi.sendUserMessage(...)` — injected as actual user input,
  tagged `<channel source="antiphon">` the way the mandate teaches the model.

## Fail-open guarantee

No daemon (no `~/.antiphon/antiphond.json`, or a stale pid) → silently inert;
the discovery file is re-checked on every connect attempt, so starting
Antiphon later just works. Reconnects back off with jitter (1–30 s); close
code 4000 ("replaced") stands down permanently. Every handler and network op
is try/caught; narration tools always return ok. Narration during an outage
is dropped except the latest done-summary (buffered depth-one, replayed on
reconnect). Zero npm dependencies.

## Install

Copy the file in (global) — no publish needed:

```sh
mkdir -p ~/.pi/agent/extensions
cp plugins/pi/index.ts ~/.pi/agent/extensions/antiphon.ts
```

Project-local: `.pi/extensions/antiphon.ts`. One-off: `pi -e plugins/pi/index.ts`.
Or, once published, add to `~/.pi/agent/settings.json`:
`{ "packages": ["npm:antiphon-pi"] }`. Hot-reload with `/reload`.

Env: `ANTIPHON_SESSION` (explicit session id), `ANTIPHON_HUB` (hub URL
override), `ANTIPHON_STATE` (state dir override, for testing).

## Known limits

- **Blocked** has no hook-driven source (Pi exposes no permission-request
  event to extensions); it comes only from the model calling
  `antiphon_blocked`.
- The mandate is only appended when `before_agent_start` supplies the current
  `systemPrompt` — if a Pi version stops passing it, we skip rather than
  clobber the host prompt, and the model won't know to narrate.
- Title updates (`session_info_changed`) aren't relayed; the room's title
  comes from the first `antiphon_task` headline (hub behavior).
