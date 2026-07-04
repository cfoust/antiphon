---
id: aider
title: Aider
---

# Aider

Aider has no plugin system — only a notification command that fires, without payload,
whenever the LLM finishes and waits for input. So this adapter is a launch wrapper with
honest, limited fidelity: presence in the room, and a nudge when Aider wants you.

## Install

```bash
cp plugins/aider/antiphon-aider ~/bin/ && chmod +x ~/bin/antiphon-aider
antiphon-aider  # instead of `aider`, same arguments
```

## What you get

- **Bind** when the wrapper launches — the session takes a seat.
- **"Waiting for you"** — Aider's notification is mapped to the blocked bloom. Because
  Aider can't distinguish *done* from *waiting for approval*, every turn-end nudges you;
  that's the API ceiling, not a bug.
- **Done** when the wrapper exits (exit codes preserved).

No tool ticks, no model-authored narration, talk-back via terminal-pane injection only.
If `aider` isn't wrapped by Antiphon or the daemon isn't running, the wrapper `exec`s
aider directly — zero cost.
