# plugins/codex — Codex CLI adapter for Antiphon

Narrates OpenAI Codex CLI sessions into the Antiphon spatial-audio monitor via
`antiphond` (protocol: `plugins/README.md`). A near-1:1 port of the Claude Code
plugin: Codex's hooks engine is Claude-Code-shaped, so the same pieces map
straight across.

## What it does

- **MCP server** (`antiphond channel`, spawned per session over stdio,
  `ANTIPHON_KIND=codex`): exposes `antiphon_task` / `antiphon_progress` /
  `antiphon_done` / `antiphon_blocked`. The model narrates; the hub voices it
  at the agent's seat in the room.
- **Hooks** (`~/.codex/hooks.json`):
  - `SessionStart` injects the narration mandate (`narration.md`) as context,
  - `UserPromptSubmit` adds a per-turn reminder (harmless no-op if Codex
    ignores this hook's stdout),
  - `PostToolUse` → backgrounded `antiphond emit -type tool` (chord tick),
  - `Stop` → `emit -type done` with `last_assistant_message` (truncated to
    400 chars) — a spoken summary even when the model forgot `antiphon_done`,
  - `PermissionRequest` → `emit -type blocked` with the approval description.

## Fail-open guarantee

Identical to the Claude Code plugin: every hook is gated on the
`~/.antiphon/antiphond.json` discovery file, every emit is backgrounded with a
500 ms timeout, every script exits 0 no matter what. Antiphon not running
costs a Codex session nothing.

## Install

```sh
sh plugins/codex/install.sh
```

Idempotent: copies the scripts + `narration.md` into `~/.codex/antiphon/`,
merges the hooks into `~/.codex/hooks.json` (existing hooks preserved, prior
Antiphon entries replaced, originals backed up as `*.bak.<timestamp>`), and
appends `[mcp_servers.antiphon]` to `~/.codex/config.toml` once. Then run
`/hooks` inside Codex one time to trust the hooks (Codex requires this for
non-managed hooks).

The `antiphond` binary is found by the same ladder as the Claude Code plugin:
`$ANTIPHOND` → the `exe` in the discovery file → PATH → Antiphon.app bundles →
`~/go/bin`.

## Known limits

- **Two registry records per session.** Codex doesn't expose its session id to
  MCP server subprocesses, so the narration channel binds under a derived
  `ppid-…` id while the hook emits use Codex's real `session_id` — the room
  shows one voiced narrator plus one hook-driven agent (ticks/done/blocked)
  for the same session. Everything works; it just occupies two seats. If that
  bothers you more than losing model narration, delete `[mcp_servers.antiphon]`
  from config.toml — hooks alone still give ticks, done summaries, and blocked.
- **Double done.** When the model calls `antiphon_done` AND the Stop hook
  fires, you can hear two summaries (in the two voices above). Remove the
  `Stop` entry from `~/.codex/hooks.json` if you prefer model-only narration.
- **Talk-back**: Codex has no inbound channel equivalent to Claude Code's
  channels preview. Run Codex inside tmux and talk-back arrives as typed
  input via the hub's tmux injection (the hooks inherit `$TMUX_PANE`, so the
  pane is discovered automatically).

Env: `ANTIPHOND` (explicit binary path), `ANTIPHON_HUB` (hub URL override),
`ANTIPHON_STATE` (state dir override, for testing).
