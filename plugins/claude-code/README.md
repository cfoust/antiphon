# plugins/claude-code — Claude Code plugin for Antiphon

Narrates a Claude Code session into the Antiphon spatial-audio monitor via
`antiphond` (see `docs/agent-bridge.md`). Ported from the voice-antiphon
prototype; the Bun subprocess is replaced by `antiphond channel` (one static Go
binary, no runtime dependency on the agent side).

## What it does

- **MCP server** (`antiphond channel`, spawned per session over stdio): exposes
  `antiphon_task` / `antiphon_progress` / `antiphon_done` / `antiphon_blocked`.
  The model narrates; the hub voices it at the agent's seat in the room.
- **Talk-back**: hub `channel` messages arrive in-session as
  `<channel source="antiphon">` events (requires the channels research preview:
  `claude --dangerously-load-development-channels server:antiphon`).
- **Hooks**: SessionStart injects the narration mandate (`hooks/narration.md`);
  UserPromptSubmit adds a per-turn reminder.

## Fail-open guarantee

Antiphon not running must cost the session nothing:

- launcher exits quietly if the `antiphond` binary is missing,
- hub dials time out at 250 ms; reconnects back off with jitter,
- narration tools ALWAYS return "ok" instantly, connected or not,
- blips during an outage are dropped; the latest done-summary is buffered
  (depth one) and delivered on reconnect.

## Install

The plugin needs two things: this plugin loaded into Claude Code, and the
`antiphond` binary findable somewhere.

**The plugin** — via the marketplace manifest at the repo root:

```sh
claude plugin marketplace add cfoust/antiphon   # or: add /path/to/antiphon (local)
claude plugin install antiphon@antiphon
```

(Dev alternative: `claude --plugin-dir "$PWD/plugins/claude-code"`.)

**The binary** — no PATH management needed in the common cases. The launcher
searches, in order: `$ANTIPHOND` → the `exe` recorded in `~/.antiphon/antiphond.json`
(i.e. whatever binary is serving right now — if the Antiphon app is running, its
bundled daemon is found automatically) → PATH → `/Applications/Antiphon.app` and
`~/Applications/Antiphon.app` bundles → the repo dev build (`antiphond/bin/`) →
`~/go/bin` (`cd antiphond && go install ./cmd/antiphond`).

Hooks are gated on `~/.antiphon/antiphond.json`: sessions on a machine where
Antiphon has never run get no narration mandate injected at all.

## Run

```sh
(cd antiphond && just build)        # builds antiphond/bin/antiphond
antiphond/bin/antiphond serve        # or just open Antiphon.app (it owns the daemon)
claude --dangerously-load-development-channels server:antiphon   # talk-back (optional)
```

Env: `ANTIPHOND` (explicit binary path), `ANTIPHON_HUB` (hub URL override,
default `ws://127.0.0.1:8787/agent`).
