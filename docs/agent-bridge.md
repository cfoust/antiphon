# Agent bridge (`antiphond`) — productionizing live agent connection

Status: **design accepted, M1 in progress** (branch `feat/agent-bridge`).

This is the production redesign of the voice-antiphon prototype's live mode
(`~/Developer/machinus/voice-chamber`: Bun hub + `cc-chamber` MCP plugin + ElevenLabs),
whose web half already lives in this repo (`web/bridge/`, `web/src/live/`). The prototype
proved the experience; this doc pins down what it takes to make agent connection a thing
you can install and forget.

## What we're building

A local daemon, **`antiphond`** (Go), that:

1. accepts connections from coding agents (Claude Code first) which send **narration**:
   model-authored blips + done summaries — the prototype proved models are good at
   summarizing their own work, so narration stays model-driven,
2. turns narration into **voice lines** via a pluggable TTS layer (ElevenLabs, macOS
   `say`, more later) with per-agent voice consistency and failure-driven fallback,
3. feeds the spatialized Antiphon clients — the **native macOS app** (primary) and the
   web app — over the same local WebSocket protocol the prototype already speaks.

```
Claude Code ──stdio/MCP──> antiphond channel (same binary, subprocess mode)
                                 │ ws://127.0.0.1:8787/agent   {hello, task, progress, done, blocked}
other agents ──HTTP POST──> /events (curl-simple adapter surface)
                                 ▼
                          antiphond serve  ── registry (identity, voices, last-seen; persisted)
                                 │            ├─ TTS chain: elevenlabs → macos-say → silent
                                 │            └─ cache ~/.antiphon/tts-cache (hash of provider+voice+text)
                                 │ ws://127.0.0.1:8787/stream  (frames + audio)
                                 ▼
                    native Antiphon app · web app (?live) · anything else
```

### Why Go (and not Rust or more Bun)

- This is orchestration: many long-lived sockets, subprocess supervision, HTTP fan-out,
  retries, state files. Goroutines + stdlib are the shortest path, and it's the
  maintainer's strongest language. The DSP core stays Rust; the boundary is a local
  socket, not FFI — no cgo anywhere (same conclusion as the prototype's
  `native-macos-plan.md`).
- One static binary. It can be bundled inside `Antiphon.app/Contents/MacOS/` and spawned
  by the app, run headless for the web app, and *also* serve as the per-session MCP
  channel subprocess (`antiphond channel`) so the Claude Code plugin ships no runtime of
  its own (the prototype needed Bun on the agent side; that dependency dies here).

## The wire contract (kept, then extended)

The prototype's frame protocol is good and the web page already speaks it — it is the
compatibility baseline. A frame's text field name depends on type
(`task→headline, progress→note, done→summary, blocked→question`):

```jsonc
// hub → antiphon clients (/stream)
{ "type":"hello",    "seats":[{"seat":0,"color":"#7aa2ff"}, ...] }
{ "type":"bind",     "seat":0, "color":"#7aa2ff", "agent":"a1b2", "name":"wren" }
{ "type":"task",     "seat":0, "color":"#7aa2ff", "agent":"a1b2", "headline":"…", "audioB64":"…", "audioUrl":"/audio/<hash>.wav", "degraded":false }
{ "type":"progress", "seat":0, …, "note":"…",     … }
{ "type":"done",     "seat":0, …, "summary":"…",  … }
{ "type":"blocked",  "seat":0, …, "question":"…", … }
{ "type":"free",     "seat":0, "agent":"a1b2" }
// antiphon client → hub (talk-back), relayed to the agent as {type:"channel", text}
{ "type":"say", "seat":0, "text":"…" }
```

Additive changes only: `agent` (registry id), `name` (voice persona), `audioUrl`
(localhost fetch — the native app streams this instead of base64), `degraded` (true when
the line was synthesized by a fallback provider). Existing web `?live` keeps working
unmodified.

**Agent side (`/agent` WS)** gains an identity handshake, fixing the prototype's biggest
gap (identity was "whichever socket connected Nth"):

```jsonc
// first message from the agent subprocess
{ "type":"hello", "session":"<uuid>", "kind":"claude-code", "repo":"cfoust/antiphon",
  "cwd":"/Users/…", "title":"fix parity drift" }
// server reply
{ "type":"seat", "seat":2, "color":"#5fd0c5", "agent":"a1b2", "voice":"wren" }
```

A reconnect presenting the same `session` reclaims its registry record — same voice,
same seat if free. A legacy client that skips `hello` gets an anonymous record
(prototype behavior, still works).

**Non-MCP agents** integrate with one HTTP call — the adapter surface for "many
different kinds of agents with varying integration quality":

```
POST /events  {"session":"…","kind":"opencode","type":"progress","text":"running tests"}
```

Narration is **model-driven** (the four MCP tools: `antiphon_task`, `antiphon_progress`,
`antiphon_done`, `antiphon_blocked`) — the prototype showed models summarize their own
work well, and that stays the only source of spoken text. Hook events are never
verbalized; a robot reading "running Bash: cargo test" is the wrong texture.

**Tool blips** are the one hook-driven event, precisely because they carry no words:
`{"type":"tool","seat":N,"agent":"a1b2"}` broadcast per tool call (the Claude Code plugin's
`PostToolUse` hook fires a backgrounded `antiphond emit -type tool`; also accepted on
`/agent` and `/events`). No text, no TTS — clients use it to tick the agent's chord
(three gently descending notes cycling per call, with the chord root breathing as a
"working" drone while blips keep arriving).

**Settings surface** (the app's Settings ▸ Voices pane): `GET/PUT /config` persists
provider enablement + API keys to `~/.antiphon/config.json` (0600; env keys stay as
fallbacks) and rebuilds the TTS ladder live; `GET /voices[?refresh=1]` reports the
runtime-discovered voice pool across all enabled providers (ElevenLabs `/v1/voices`,
`say -v ?` minus the novelty voices, OpenAI's static list). Each new session draws a
random voice from that pool — sticky in the registry (`tts_provider`/`tts_voice`),
with the persona's `macos-say` realization kept as the offline floor.

## Integrating a new coding agent: zero server changes, by design

The server knows nothing about specific agents — `kind` is a free string, identity is
whatever session key the client presents, and the protocol (`hello` + four narration
events) is the whole contract. There is deliberately no per-agent code path to add.
An agent integrates at whichever rung it can reach:

1. **`antiphond emit`** — the floor. If the agent can run arbitrary commands (hooks,
   wrappers, CI steps), it is already integrable:

   ```sh
   antiphond emit -type task -text "reworking the auth flow"
   antiphond emit -type done -text "Tests pass; the flow uses refresh tokens now."
   ```

   Session/repo identity is derived (or passed via `-session`/`ANTIPHON_SESSION`);
   the hub is found through the discovery file, so a missing daemon costs ~10 ms and
   nothing else. Always exits 0, never writes stdout — safe to call unconditionally
   from any hook pipeline.
2. **`POST /events`** — same thing over plain HTTP for agents that would rather
   speak JSON than exec a binary.
3. **`/agent` WebSocket** — the full-fidelity rung: persistent identity, instant
   `bind/free` presence, and talk-back delivery. This is what `antiphond channel`
   (the Claude Code MCP driver) uses.

So yes: an agent that can administer hooks and run commands needs nothing else — for
narration OUT *and*, in most real setups, for talk-back IN too (see below).

## Talk-back: the input ladder

Delivering the user's words INTO an agent uses a per-agent **input target**, reported
in the `hello`/`/events` payload (`"input": {kind, target, socket?}`), persisted on the
registry record, and used by the hub to route `say`. Kinds form a quality ladder:

1. **`http`** — the agent has a real programmatic API (OpenCode does; aider and pi
   likely too): `target` is a URL accepting `POST {"text":"…"}`. Agents whose native
   API shape differs front it with a tiny local shim. Most precise, no terminal side
   effects — preferred when reported.
2. **`tmux` / `cy`** — the generic floor: type the text + Enter into the pane the
   agent lives in (`tmux send-keys -l` so nothing is interpreted). The beauty is that
   ANY subprocess of the agent inherits the multiplexer env (`$TMUX_PANE`, `$CY`), so
   `antiphond channel` and even a hook-level `antiphond emit` discover the pane
   automatically — a hooks-only integration is *bidirectional* for free when it runs
   under a mux. cy: `$CY = <socket>:<node-id>` identifies the pane; injection is
   `cy -L <socket> exec` running `(pane/send-text id …)` + `(pane/send-keys id
   @["enter"])`, with `$CY` STRIPPED from the exec's environment — cy's CLI prefers
   the env context over `-L`, so a daemon living inside a cy pane would otherwise
   hijack itself to its own server.
3. **MCP channel** — Claude-Code-specific fallback for socket-connected agents outside
   any known pane (requires the channels research preview).

**Reachability is user-visible**: `bind` frames and `GET /agents` carry
`"input": "http"|"tmux"|"cy"|"channel"|""` — empty means the session can be heard but
not spoken to, and clients should indicate that. A failed injection (pane died)
clears the stored target so the flag stays honest.

## Adding a TTS provider

One Go interface, two methods, no other integration points:

```go
type Provider interface {
    Name() string
    Synthesize(ctx, voiceID, text string, lowLatency bool) (audio []byte, ext string, err error)
}
```

Register it in the ladder (priority order in `main.go`) and give personas a
realization for it in the roster (`"name": {"realizations": {"yourprovider": "voice-id"}}`).
Breaker, caching, degradation flags, and voice stickiness all come for free from the
chain — a provider implementation is typically <100 lines (see `elevenlabs.go`).

**Management surface** (the future many-agents UX builds on this, API-first):

```
GET  /agents            → [{agent, session, kind, repo, title, voice, seat,
                            connected, created_at, last_seen_at, last_event_at}]
DELETE /agents/{id}     → evict (frees seat + voice binding, tombstones the record)
GET  /health            → {ok, agents:[…]}   (kept from prototype)
POST /debug/emit        → drive frames with no session (kept; the mock/test harness)
```

## Agent lifecycle: identity, staleness, liveness

The registry is the source of truth, persisted to `~/.antiphon/agents.json` (atomic
write; tiny data). Per agent:

- `created_at`, `last_seen_at` (any socket traffic / reconnect), `last_event_at`
  (last *meaningful* narration event) — these are deliberately separate because
  **liveness is fuzzy**: a connected socket doesn't mean the driver behind it is alive,
  and a disconnected socket doesn't mean the session is gone (the subprocess retries
  forever). UX later decides what "stale" means; the API just tells the truth.
- `connected` (bool, derived from socket state) — *not* persisted as fact, recomputed.
- States are derived, not stored: `active` (recent event), `idle` (connected, quiet),
  `disconnected` (record retained). Eviction is explicit (`DELETE`) now; a retention
  policy (e.g. auto-evict after N days disconnected) is config later, once the
  management UX exists. This is how we avoid 10–15 dead sessions squatting seats:
  **seats and registry records are decoupled.**

**Seats** are the spatial slots in the antiphon (6 today). More agents than seats is
expected: seatless agents live in the registry and get a seat on their next event,
stealing from the longest-idle seated agent (bind/free frames make the swap audible and
visible). The prototype's "overflow piles onto the last seat" dies.

## TTS: providers, voices, and the fallback ladder

Two separate concepts, deliberately decoupled:

- A **provider** is an engine: `elevenlabs`, `macos-say`, later `openai`, local
  neural TTS (piper/kokoro), etc. Providers have *health* (see ladder) and *cost*.
- A **voice** is a persistent persona (`atlas`, `echo`, `wren`, `cass`, `iris`, `rook` —
  name, color) with a **realization per provider**: wren = ElevenLabs `EXAVITQu…`
  *and* macOS `Samantha`. New voices = new roster entries (JSON, `--roster` /
  `~/.antiphon/roster.json`); new providers = a Go interface implementation plus one
  realization column in the roster.

**Consistency rule:** an agent is bound to a *voice persona* for the lifetime of its
registry record — never rebound while alive, persisted across reconnects. Provider
failure changes the *realization*, not the persona: wren stays "wren" (same seat, color,
name) even when ElevenLabs credit runs out and she suddenly speaks with the macOS voice.
Frames carry `degraded:true` so clients can whisper that fact in the UI. When the
preferred provider recovers, realization upgrades again — persona unbroken.

**The ladder is failure-driven, nothing more** — per synthesized line:

1. Walk the provider priority list (config; default `elevenlabs, macos-say`) and use the
   first provider that (a) has a realization for this voice and (b) is healthy.
2. Health = circuit breaker per provider: 3 consecutive failures → open for 60 s
   (skipped without trying) → half-open single probe → close on success. This is what
   turns "ElevenLabs API calls just started failing" (credits exhausted, network down,
   whatever) from a 30-second timeout on *every* line into one clean, instant
   degradation — and what upgrades the voice back automatically when it recovers.
3. `macos-say` is the floor on macOS: always installed, free, offline. If even that
   fails, the frame ships without audio and the antiphon shows text silently — exactly
   the prototype's no-API-key behavior.

**Caching:** every rendered line is content-addressed
(`sha256(provider, realization, text)`) in `~/.antiphon/tts-cache/` and served at
`/audio/{hash}.wav|mp3`. Repeated lines (agents repeat themselves *constantly*) cost
nothing, and the native app can stream the file instead of decoding base64 out of JSON.
`macos-say` renders `WAVE/LEI16@48000` — natively matched to the engine's pinned 48 kHz.

## Failure isolation: Antiphon down must cost agents nothing

The seam into the agent must be invisible when Antiphon isn't in use:

- Every hook/plugin touchpoint is **fail-open**: hard connect timeout (250 ms to
  localhost), silent no-op on any failure, always exit 0 / always return "ok" to the
  model. The prototype already did this right (tool calls return "ok" regardless);
  we keep that and add the timeout discipline.
- The channel subprocess (`antiphond channel`) retries with capped backoff **+ jitter**
  (prototype: 1 s tight loop forever — fine for one session, noisy for fifteen).
  Blips during an outage are dropped (they're ephemeral by definition); the **latest
  done-summary is held** (buffer of one) and delivered on reconnect — that's the line
  with durable value.
- Cheap discovery: `antiphond serve` writes `~/.antiphon/antiphond.json`
  (`{port, pid, started_at}`) on start and removes it on clean exit. Clients check the
  file before ever touching the network; a stale file (dead pid) reads as "not running".
- The native app **owns the daemon** on macOS: spawn on launch if not running, adopt if
  running, supervise/restart. Standalone `antiphond serve` stays first-class for web/dev.
  (launchd socket activation is a possible later refinement, not a dependency.)

## Install & distribution

- **Plugin**: a marketplace manifest lives at the repo root
  (`.claude-plugin/marketplace.json`), so real installs are
  `claude plugin marketplace add cfoust/antiphon` + `claude plugin install
  antiphon@antiphon`; `--plugin-dir` remains the dev path. See `plugins/claude-code/README.md`.
- **Binary**: nothing needs PATH. The daemon records its own executable path in the
  discovery file, so the plugin launcher finds whatever binary is serving (e.g. the
  copy inside Antiphon.app); it also checks `/Applications`/`~/Applications` bundles,
  the repo dev build, and `~/go/bin`. `$ANTIPHOND` overrides everything.
- **Hooks are gated** on `~/.antiphon/antiphond.json` existing: machines where Antiphon
  has never run get zero prompt injection from the plugin.

## Claude Code integration (`plugins/claude-code`, rebuilt here)

Port the prototype plugin into this repo with the runtime dependency removed:

- `.mcp.json` spawns `antiphond channel` (the bundled binary; `ANTIPHON_HUB` overridable).
  Same four narration tools (`antiphon_task`, `antiphon_progress`, `antiphon_done`,
  `antiphon_blocked`), same `claude/channel` inbound path for talk-back.
- `channel` mode sends the identity `hello` (session id from CC env, repo from git
  remote/cwd, title from the first task headline).
- Hooks do two jobs: the prototype's prompt nudges (SessionStart narration mandate +
  UserPromptSubmit reminder) AND **PostToolUse matchers emitting cue events** (tool
  name → cue kind, fire-and-forget). The optional Stop-backstop stays optional.
- Everything above obeys the fail-open contract.

## Milestones

- **M0** — this document. ✅
- **M1** ✅ — `antiphond serve` skeleton (this branch): registry w/ persistence + identity,
  `/agent` `/stream` `/events` `/agents` `/health` `/debug/emit`, prototype-compatible
  frames, TTS chain (`elevenlabs` + `macos-say` + breaker + cache), roster with sticky
  voice binding. Verified with a headless WS test.
- **M2** ✅ — `antiphond channel` (MCP subprocess mode) + `plugins/claude-code/` plugin in this repo;
  end-to-end with a real Claude Code session. Fail-open verified by killing the daemon
  mid-session.
- **M3** ✅ — native app client: WebSocket to `/stream`, live narration buffers replacing
  the canned mp3 loops (the `AgentRuntime` mixing path already takes 48 k mono floats),
  daemon spawn/supervision, `bind/free` driving agent presence on the radar.
- **M4** — management UX (list/evict/idle handling) on top of `GET /agents`;
  provider/voice config surface; more providers.

## Open questions (parked deliberately)

- **Hook-driven mechanical cues** — mapping tool activity (edits, shell calls, reads)
  to NON-VERBAL sound texture (typing, key clacks) at the agent's position via
  PostToolUse hooks and a `{type:"cue", kind}` event. Explicitly out of scope for now;
  it's additive to the wire protocol whenever we want it, and like the attention cue
  the sounds could eventually live in `antiphon-dsp` itself.
- Auth: localhost-only bind is the current stance (like the prototype). If we ever bind
  beyond loopback, a bearer token in `antiphond.json` is the shape.
- Audio transport for very long lines: current model is whole-line render; streaming TTS
  (ElevenLabs websocket API) is a latency refinement that doesn't change the contract
  (`audioUrl` can point at a growing file).
- Web app auto-start of the daemon (no app to own it) — probably "just run
  `just bridge`" forever, docs suffice.
