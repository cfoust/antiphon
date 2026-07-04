# plugins/ — coding-agent adapters for Antiphon

Each directory teaches one coding agent to narrate into `antiphond`, the
Antiphon daemon (see `docs/agent-bridge.md`).

**The protocol, in one paragraph.** An agent binds by sending
`{type:"hello", session, kind, repo, cwd, title, input}` on the
`ws://127.0.0.1:<port>/agent` WebSocket (or the same fields with each
one-shot `POST /events`, or via the `antiphond emit` CLI), then sends events
`{type, text}` where type is `task` (headline, also titles the agent),
`progress` (short note), `done` (spoken summary), `blocked` (question) — all
voiced by TTS at the agent's seat in the room — plus `tool`, a textless
broadcast-only blip per tool call that ticks the agent's chord. The hub may
push `{type:"channel", text}` down the socket: the user speaking to the agent
from the room (talk-back). The daemon is discovered through
`~/.antiphon/antiphond.json`; every adapter is fail-open — Antiphon absent or
down must cost the host agent nothing.

## Support matrix

| capability            | claude-code | codex | opencode | pi | aider |
|-----------------------|:-----------:|:-----:|:--------:|:--:|:-----:|
| bind + title          | ✅ | ✅ ¹ | ✅ | ✅ | ✅ (launch wrapper) |
| tool ticks            | ✅ | ✅ | ✅ | ✅ | — |
| narration (task/progress, model-authored) | ✅ MCP | ✅ MCP | ✅ plugin tools | ✅ registered tools | — |
| spoken done summary   | ✅ model | ✅ model + Stop-hook backstop | ✅ model + idle backstop | ✅ model + agent_end backstop | canned "session ended" |
| blocked / needs-input | ✅ model | ✅ PermissionRequest + model | ✅ permission event + model | model tools only ² | ⚠️ every turn-end ³ |
| talk-back             | ✅ channel (preview) / tmux | tmux only | best-effort SDK + tmux | ✅ `pi.sendUserMessage` | tmux only |

¹ Codex sessions appear as two registry records (narration channel + hook
emits) because Codex doesn't expose its session id to MCP subprocesses — see
`codex/README.md`.
² Pi exposes no permission-request event to extensions.
³ Aider can't distinguish "done" from "waiting for approval"; its single
notification is mapped to a blocked-style "waiting for you" ping.

## Install one-liners

```sh
# claude-code — marketplace plugin
claude plugin marketplace add cfoust/antiphon && claude plugin install antiphon@antiphon

# codex — idempotent merge into ~/.codex (then run /hooks once inside Codex)
sh plugins/codex/install.sh

# opencode — single-file plugin
cp plugins/opencode/index.ts ~/.config/opencode/plugins/antiphon.ts

# pi — single-file extension
cp plugins/pi/index.ts ~/.pi/agent/extensions/antiphon.ts

# aider — launch wrapper
cp plugins/aider/antiphon-aider ~/bin/ && chmod +x ~/bin/antiphon-aider
```

Everything needs the `antiphond` binary findable (Antiphon.app running, or
`cd antiphond && just build`, or `go install ./cmd/antiphond`); the shell
adapters share the same search ladder as the Claude Code plugin
(`$ANTIPHOND` → discovery-file `exe` → PATH → app bundles → `~/go/bin`), and
the TS adapters read the hub port straight from the discovery file.
