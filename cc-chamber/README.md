# cc-chamber — Claude Code plugin for Chamber

Narrates a Claude Code session into the Chamber spatial-audio monitor via
`chamberd` (see `docs/agent-bridge.md`). Ported from the voice-chamber
prototype; the Bun subprocess is replaced by `chamberd channel` (one static Go
binary, no runtime dependency on the agent side).

## What it does

- **MCP server** (`chamberd channel`, spawned per session over stdio): exposes
  `chamber_task` / `chamber_progress` / `chamber_done` / `chamber_blocked`.
  The model narrates; the hub voices it at the agent's seat in the room.
- **Talk-back**: hub `channel` messages arrive in-session as
  `<channel source="chamber">` events (requires the channels research preview:
  `claude --dangerously-load-development-channels server:chamber`).
- **Hooks**: SessionStart injects the narration mandate (`hooks/narration.md`);
  UserPromptSubmit adds a per-turn reminder.

## Fail-open guarantee

Chamber not running must cost the session nothing:

- launcher exits quietly if the `chamberd` binary is missing,
- hub dials time out at 250 ms; reconnects back off with jitter,
- narration tools ALWAYS return "ok" instantly, connected or not,
- blips during an outage are dropped; the latest done-summary is buffered
  (depth one) and delivered on reconnect.

## Install

The plugin needs two things: this plugin loaded into Claude Code, and the
`chamberd` binary findable somewhere.

**The plugin** — via the marketplace manifest at the repo root:

```sh
claude plugin marketplace add cfoust/chamber   # or: add /path/to/chamber (local)
claude plugin install chamber@chamber
```

(Dev alternative: `claude --plugin-dir "$PWD/cc-chamber"`.)

**The binary** — no PATH management needed in the common cases. The launcher
searches, in order: `$CHAMBERD` → the `exe` recorded in `~/.chamber/chamberd.json`
(i.e. whatever binary is serving right now — if the Chamber app is running, its
bundled daemon is found automatically) → PATH → `/Applications/Chamber.app` and
`~/Applications/Chamber.app` bundles → the repo dev build (`chamberd/bin/`) →
`~/go/bin` (`cd chamberd && go install ./cmd/chamberd`).

Hooks are gated on `~/.chamber/chamberd.json`: sessions on a machine where
Chamber has never run get no narration mandate injected at all.

## Run

```sh
(cd chamberd && just build)        # builds chamberd/bin/chamberd
chamberd/bin/chamberd serve        # or just open Chamber.app (it owns the daemon)
claude --dangerously-load-development-channels server:chamber   # talk-back (optional)
```

Env: `CHAMBERD` (explicit binary path), `CHAMBER_HUB` (hub URL override,
default `ws://127.0.0.1:8787/agent`).
