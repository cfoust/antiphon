/**
 * antiphon-opencode — narrate OpenCode sessions into Antiphon, the
 * spatial-audio agent monitor (protocol: plugins/README.md).
 *
 * Runs in-process (Bun), so it speaks the hub's /agent WebSocket protocol
 * directly: one persistent connection per OpenCode session, identity hello on
 * (re)connect, narration frames, tool ticks, and talk-back ({type:"channel"})
 * injected back into the session.
 *
 * Fail-open everywhere: no daemon (no ~/.antiphon/antiphond.json) means the
 * plugin is silently inert; every network op is try/caught; nothing here may
 * ever break the host agent. Zero dependencies beyond builtins — the optional
 * import of "@opencode-ai/plugin" (for custom-tool registration) is the host's
 * own package and is skipped gracefully when unresolvable.
 */
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join, basename } from "node:path"
import { execSync } from "node:child_process"

const STATE = process.env.ANTIPHON_STATE ?? join(homedir(), ".antiphon")

const NARRATION = `Narrate your work into the Antiphon (required): this session is monitored
by ear — the user hears you as a voice in a virtual room. Call antiphon_task once when you
begin something new (one short spoken headline; it also becomes this session's title in
the room — call it in your first reply so your seat is never unnamed). Call antiphon_progress BEFORE each meaningful
step — one short, plain, spoken sentence, every time you switch activity; conversational, no
file paths or code. Call antiphon_done when the task is complete (a TWO-sentence spoken summary
of what you did and the outcome). Call antiphon_blocked when you need the user (one clear
question). Do your normal work as usual and don't mention these calls in your text replies —
the narration is the audio channel. Messages arriving in <channel source="antiphon"> tags are
the user speaking to you from the room; treat them as user input.`

// hubUrl resolves the /agent WebSocket URL, or null when the daemon isn't
// running. Mirrors antiphond's own discovery discipline: $ANTIPHON_HUB wins,
// else the discovery file, whose pid must be alive (stale file = not running).
function hubUrl(): string | null {
  if (process.env.ANTIPHON_HUB) return process.env.ANTIPHON_HUB
  try {
    const d = JSON.parse(readFileSync(join(STATE, "antiphond.json"), "utf8"))
    if (!d?.port) return null
    if (d.pid) process.kill(d.pid, 0) // throws if dead
    return `ws://127.0.0.1:${d.port}/agent`
  } catch {
    return null
  }
}

// detectInput mirrors antiphond/internal/input.Detect: report the tmux/cy pane
// this process lives in so the hub can type talk-back into it.
function detectInput(): Record<string, string> | null {
  const pane = process.env.TMUX_PANE
  if (pane) {
    const info: Record<string, string> = { kind: "tmux", target: pane }
    const t = process.env.TMUX ?? ""
    const i = t.indexOf(",")
    if (i > 0) info.socket = t.slice(0, i)
    return info
  }
  const cy = process.env.CY ?? ""
  const i = cy.indexOf(":")
  if (i > 0) return { kind: "cy", socket: cy.slice(0, i), target: cy.slice(i + 1) }
  return null
}

function repoName(dir: string): string {
  try {
    const top = execSync("git rev-parse --show-toplevel", {
      cwd: dir, timeout: 500, stdio: ["ignore", "pipe", "ignore"],
    }).toString().trim()
    if (top) return basename(top)
  } catch {}
  return basename(dir || "unknown")
}

// spoken flattens text into something worth speaking: code blocks dropped,
// whitespace collapsed, cut at a sentence boundary near `max`.
function spoken(text: string, max = 400): string {
  const t = String(text).replace(/```[\s\S]*?```/g, " ").replace(/\s+/g, " ").trim()
  if (t.length <= max) return t
  const cut = t.slice(0, max)
  const dot = cut.lastIndexOf(". ")
  return dot > max / 2 ? cut.slice(0, dot + 1) : cut
}

const DONE_REPLAY_TTL = 5 * 60 * 1000 // hold the latest done across an outage

// Conn is one session's persistent /agent socket: hello on every (re)connect,
// capped backoff with jitter, stand-down on close code 4000 (replaced by a
// newer connection — never fight it for the seat).
class Conn {
  private ws: WebSocket | null = null
  private dialing = false // a second open() while the socket handshakes must NOT dial again
  private replaced = false
  private closed = false
  private retry = 1000
  private timer: ReturnType<typeof setTimeout> | null = null
  private pendingDone: { text: string; at: number } | null = null
  seat = -1
  onChannel: ((text: string) => void) | null = null

  constructor(private hello: Record<string, unknown>) {}

  open() {
    if (this.ws || this.dialing || this.timer || this.replaced || this.closed) return
    this.dial()
  }

  private dial() {
    this.dialing = true
    try {
      const url = hubUrl()
      const WS = (globalThis as { WebSocket?: typeof WebSocket }).WebSocket
      if (!url || !WS) return this.later()
      const ws = new WS(url)
      ws.onopen = () => {
        try {
          this.dialing = false
          this.retry = 1000
          this.ws = ws
          ws.send(JSON.stringify({ type: "hello", ...this.hello }))
          if (this.pendingDone && Date.now() - this.pendingDone.at < DONE_REPLAY_TTL) {
            ws.send(JSON.stringify({ type: "done", text: this.pendingDone.text }))
          }
          this.pendingDone = null
        } catch {}
      }
      ws.onmessage = (m: MessageEvent) => {
        try {
          const f = JSON.parse(String(m.data))
          if (f?.type === "seat" && typeof f.seat === "number") this.seat = f.seat
          if (f?.type === "channel" && typeof f.text === "string") this.onChannel?.(f.text)
        } catch {}
      }
      ws.onclose = (ev: CloseEvent) => {
        this.dialing = false
        this.ws = null
        if (ev?.code === 4000) { this.replaced = true; return }
        if (!this.closed) this.later()
      }
      ws.onerror = () => {} // onclose follows; nothing to do
    } catch {
      this.later()
    }
  }

  private later() {
    this.dialing = false
    if (this.closed || this.replaced || this.timer) return
    const delay = this.retry / 2 + Math.random() * (this.retry / 2)
    this.retry = Math.min(this.retry * 2, 30000)
    this.timer = setTimeout(() => { this.timer = null; this.dial() }, delay)
    ;(this.timer as { unref?: () => void })?.unref?.()
  }

  // send relays one event. Frames during an outage are dropped (ephemeral by
  // definition) except the latest done-summary, buffered depth-one and
  // replayed on reconnect — that's the line with durable value.
  send(type: string, text = "") {
    if (!this.ws) {
      if (type === "done" && text) { this.pendingDone = { text, at: Date.now() }; this.open() }
      return
    }
    try { this.ws.send(JSON.stringify(text ? { type, text } : { type })) } catch {}
  }

  close() {
    this.closed = true
    if (this.timer) { clearTimeout(this.timer); this.timer = null }
    try { this.ws?.close() } catch {}
    this.ws = null
  }
}

export const AntiphonPlugin = async (ctx: any = {}) => {
  const dir: string = ctx.worktree ?? ctx.directory ?? process.cwd()
  const repo = repoName(dir)
  const conns = new Map<string, Conn>()
  const lastText = new Map<string, string>() // session → latest assistant text
  const roles = new Map<string, string>() // message id → role
  const doneAt = new Map<string, number>() // session → last model-narrated done
  let lastSession: string | null = null

  // talkback injects the user's words from the room as a real user message.
  // Best-effort: the SDK surface is client.session.prompt; anything else is
  // swallowed (talk-back then only works via tmux injection).
  const talkback = async (sid: string, text: string) => {
    try {
      await ctx.client?.session?.prompt?.({
        path: { id: sid },
        body: { parts: [{ type: "text", text: `<channel source="antiphon">${text}</channel>` }] },
      })
    } catch {}
  }

  const ensure = (sid?: string, title?: string): Conn | null => {
    if (!sid) return null
    lastSession = sid
    let c = conns.get(sid)
    if (!c) {
      const hello: Record<string, unknown> = { session: sid, kind: "opencode", repo, cwd: dir }
      if (title) hello.title = title
      const input = detectInput()
      if (input) hello.input = input
      c = new Conn(hello)
      c.onChannel = (text) => { void talkback(sid, text) }
      conns.set(sid, c)
    }
    c.open()
    return c
  }

  const narrate = (sid: string | null, type: string, text: string) => {
    if (!sid || !text) return
    ensure(sid)?.send(type, spoken(text))
    if (type === "done") doneAt.set(sid, Date.now())
  }

  const hooks: any = {
    event: async ({ event }: any = {}) => {
      try {
        const t = String(event?.type ?? "")
        const p = event?.properties ?? {}
        if (t === "session.created" || t === "session.updated") {
          const info = p.info ?? p.session ?? {}
          if (info.id && !info.parentID) ensure(info.id, info.title) // subagent child sessions stay silent
        } else if (t === "session.deleted") {
          const id = p.info?.id ?? p.sessionID
          if (id) {
            conns.get(id)?.close()
            conns.delete(id)
            lastText.delete(id)
            doneAt.delete(id)
          }
        } else if (t === "session.idle") {
          const id = p.sessionID ?? p.info?.id
          if (!id || !conns.has(id)) return
          if (Date.now() - (doneAt.get(id) ?? 0) < 30000) return // the model already said done
          const text = (lastText.get(id) ?? "").trim()
          if (text) narrate(id, "done", text)
        } else if (t.startsWith("permission.") && t !== "permission.replied") {
          const id = p.sessionID ?? p.permission?.sessionID ?? p.info?.sessionID
          const what = p.title ?? p.permission?.title ?? p.metadata?.title
          narrate(id ?? lastSession, "blocked",
            what ? `May I go ahead? ${what}` : "OpenCode needs your approval to continue.")
        } else if (t === "message.updated") {
          const info = p.info ?? {}
          if (info.id && info.role) roles.set(info.id, info.role)
        } else if (t === "message.part.updated") {
          const part = p.part ?? {}
          if (part.type === "text" && part.sessionID && roles.get(part.messageID) !== "user") {
            lastText.set(part.sessionID, String(part.text ?? ""))
          }
        }
      } catch {}
    },

    "tool.execute.after": async (input: any = {}) => {
      try {
        if (String(input?.tool ?? "").startsWith("antiphon_")) return // our own narration isn't a tick
        ensure(input?.sessionID ?? lastSession ?? undefined)?.send("tool")
      } catch {}
    },

    // Inject the narration mandate into the system prompt (experimental hook:
    // harmless when the host never calls it; gated on the daemon running so a
    // machine without Antiphon gets zero prompt noise).
    "experimental.chat.system.transform": async (_input: any, output: any) => {
      try {
        if (hubUrl() && Array.isArray(output?.system)) output.system.push(NARRATION)
      } catch {}
    },
  }

  // Custom narration tools — registered only when the host's plugin package
  // resolves (it always does inside OpenCode; never under a bare test runner).
  let tool: any = null
  try {
    const mod = "@opencode-ai/plugin"
    tool = (await import(mod)).tool
  } catch {}
  if (typeof tool === "function" && tool.schema?.string) {
    const mk = (type: string, arg: string, desc: string, argDesc: string) =>
      tool({
        description: desc,
        args: { [arg]: tool.schema.string().describe(argDesc) },
        async execute(args: any, tctx: any) {
          try {
            narrate(tctx?.sessionID ?? lastSession, type, String(args?.[arg] ?? "").trim())
          } catch {}
          return "ok" // ALWAYS ok, instantly — hub trouble never surfaces to the model
        },
      })
    hooks.tool = {
      antiphon_task: mk("task", "headline", "Announce the task you are starting; the headline also becomes this session's title in the room.", "One short headline, spoken aloud."),
      antiphon_progress: mk("progress", "note", "Report what you are doing right now.", "A few words, present tense."),
      antiphon_done: mk("done", "summary", "Report that you finished.", "1-2 spoken sentences summarizing the outcome."),
      antiphon_blocked: mk("blocked", "question", "Ask the user a question you are blocked on.", "One clear question."),
    }
  }

  return hooks
}
