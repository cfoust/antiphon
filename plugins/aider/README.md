# plugins/aider — aider wrapper for Antiphon

Runs aider with a presence in the Antiphon spatial-audio monitor. This is the
**low-fidelity floor**, stated plainly: aider's entire event surface is
`--notifications-command`, a payload-less command fired when the LLM finishes
a response and waits for input. There are no session/tool hooks and no plugin
system (the Python scripting API is explicitly unsupported).

## What you get

- **Bind at launch**: `antiphond emit -type task -text "aider session in
  <repo>"` — seats the agent and titles it.
- **Per-turn ping**: the notification fires → spoken blocked line, "aider is
  waiting for you". Aider *conflates done and blocked* — both end as "waiting
  for input" — so every turn ends with this same line; we map it to `blocked`
  because "come look" is the actionable meaning.
- **Done at exit**: a spoken "the aider session ended" when the wrapper exits.

## What you don't get

No model-authored narration, no tool ticks, no real done summaries (the
notification carries no text), no distinction between "finished" and "needs
your approval", no talk-back channel (run inside tmux and the hub can still
type into the pane — the launch emit inherits `$TMUX_PANE`, so the input
target is discovered automatically).

## Fail-open guarantee

No `antiphond` binary → the wrapper is exactly `exec aider "$@"`. Daemon not
running → `antiphond emit` is a ~10 ms stat and a silent no-op (always exits
0). Aider's exit code is preserved.

## Install

```sh
cp plugins/aider/antiphon-aider ~/bin/   # anywhere on PATH
chmod +x ~/bin/antiphon-aider
antiphon-aider [usual aider args...]
```

Or make it the default: `alias aider='antiphon-aider'`.

Note: the wrapper passes `--notifications --notifications-command` on the
command line, which overrides any `notifications-command` in
`~/.aider.conf.yml`.

Env: `ANTIPHOND` (explicit binary path), `ANTIPHON_SESSION` (explicit session
id; default `aider-<pid>`), `ANTIPHON_STATE` (state dir override, for testing).
