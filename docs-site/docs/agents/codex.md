---
id: codex
title: Codex CLI
---

# Codex CLI

Codex's hooks engine is nearly the same shape as Claude Code's, so this adapter is close
to a 1:1 port: tool ticks, model-authored narration over MCP, spoken summaries with a
Stop-hook backstop, and blocked notifications from permission requests.

## Install

```bash
sh plugins/codex/install.sh
```

The installer merges idempotently into `~/.codex/` (existing hooks are preserved, backups
are timestamped): hook entries in `hooks.json`, an MCP server block in `config.toml`, and
the adapter scripts under `~/.codex/antiphon/`. Then run `/hooks` once inside Codex to
trust the new hooks.

## What you get

- **Session start** injects the narration mandate, so the model calls `antiphon_task` /
  `antiphon_progress` / `antiphon_done` / `antiphon_blocked` as it works.
- **Every tool call** ticks the agent's chord (`PostToolUse` → `antiphond emit`).
- **Stop** emits the last assistant message as a spoken summary if the model didn't
  narrate its own.
- **Permission requests** ring the waiting bloom with the request description.

## Quirks

- Codex doesn't expose its session id to MCP subprocesses, so a Codex session can appear
  as **two registry records** (the narration channel and the hook emits). Cosmetic — both
  speak from the room — but worth knowing.
- Talk-back from the room reaches Codex through terminal-pane injection (tmux) only.

Everything is fail-open: without Antiphon running, Codex behaves as if nothing were
installed.
