# plugins/opencode — OpenCode plugin for Antiphon

Narrates OpenCode sessions into the Antiphon spatial-audio monitor via
`antiphond` (see `docs/internal/agent-bridge.md`). Runs in-process, so it speaks the
hub's `/agent` WebSocket protocol natively — the same full-fidelity rung as
the Claude Code plugin's `antiphond channel`.

## What it does

- **Bind**: `session.created`/`session.updated` → identity hello (session id,
  `kind: opencode`, repo, cwd, title, tmux/cy input target). One persistent
  socket per OpenCode session; subagent child sessions stay silent.
- **Tool ticks**: `tool.execute.after` → `{type:"tool"}` blip (chord tick).
- **Narration tools**: `antiphon_task` / `antiphon_progress` / `antiphon_done`
  / `antiphon_blocked` registered as native tools; the narration mandate is
  injected via the `experimental.chat.system.transform` hook (experimental —
  harmless if your OpenCode version doesn't call it, but then the model won't
  know to narrate unless you tell it).
- **Done backstop**: `session.idle` → spoken done with the last assistant
  message text (tracked from message events), skipped when the model already
  called `antiphon_done` in the last 30 s.
- **Blocked**: `permission.asked` → spoken blocked with the approval title.
- **Talk-back**: hub `{type:"channel"}` frames are injected as a user message
  via the SDK (`client.session.prompt`, best-effort — unverified across
  OpenCode versions; try/caught). Running under tmux also gives the hub's
  generic pane injection as a fallback.

## Fail-open guarantee

No daemon (no `~/.antiphon/antiphond.json`, or a stale one) → the plugin is
silently inert; it re-checks the discovery file on every connect attempt, so
starting Antiphon later just works. Reconnects back off with jitter (1–30 s);
close code 4000 ("replaced") stands down permanently. Every hook body and
network op is try/caught. Narration during an outage is dropped except the
latest done-summary (buffered depth-one, replayed on reconnect). Zero npm
dependencies — Bun's builtin WebSocket + node builtins only; the
`@opencode-ai/plugin` import (tool registration) is the host's own package
and is skipped gracefully when absent.

## Install

Either path:

```jsonc
// opencode.json or ~/.config/opencode/opencode.json
{ "plugin": ["antiphon-opencode"] }          // once published to npm
```

or drop the file in directly (no publish needed):

```sh
mkdir -p ~/.config/opencode/plugins
cp plugins/opencode/index.ts ~/.config/opencode/plugins/antiphon.ts
```

(Project-local: `.opencode/plugins/antiphon.ts`.)

Env: `ANTIPHON_HUB` (hub URL override, default from the discovery file),
`ANTIPHON_STATE` (state dir override, for testing).

## Known limits

- MCP-provided tools may not fire `tool.execute.after` (OpenCode issue #2319)
  — those calls won't tick.
- The system-prompt transform hook is `experimental.*`; pin versions if you
  rely on the mandate injection.
- Talk-back via the SDK is best-effort; tmux injection is the reliable floor.
