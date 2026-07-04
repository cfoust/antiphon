---
id: index
title: Connecting agents
---

# Connecting agents

Antiphon listens to agent sessions through small adapters that talk to the local `antiphond`
daemon. Every adapter is **fail-open**: if Antiphon isn't installed or isn't running, your
agent behaves exactly as if the plugin didn't exist. Nothing ever blocks a session on the
daemon.

## What an adapter reports

| Event | What you hear |
| --- | --- |
| Session starts | The agent takes a seat in the room |
| Tool call | One note of the agent's chord |
| Narration | Short first-person progress lines, spoken |
| Done | A one-or-two-sentence summary, spoken from its seat |
| Blocked / needs you | The slow waiting bloom in one ear |

Fidelity varies by what each agent's extension API exposes — see each page for its exact
support matrix.

## Supported today

- [Claude Code](./claude-code.md) — the reference integration
- [Codex CLI](./codex.md)
- [OpenCode](./opencode.md)
- [Pi](./pi.md)
- [Aider](./aider.md)

## Your agent here

The protocol is deliberately small: a WebSocket to `127.0.0.1` (`/agent`) or one-shot
events through `antiphond emit`. Read any adapter in
[`plugins/`](https://github.com/cfoust/antiphon/tree/main/plugins) — the smallest is a
single file. PRs welcome.
