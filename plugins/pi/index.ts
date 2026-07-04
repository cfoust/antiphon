/**
 * antiphon-pi — Pi (badlogic/pi-mono coding-agent) extension narrating the
 * session into Antiphon, the spatial-audio agent monitor (docs/agent-bridge.md).
 *
 * Runs in-process, so it holds one persistent /agent WebSocket: identity hello
 * on (re)connect, narration frames from four registered antiphon_* tools, tool
 * ticks from tool_execution_start, a done backstop from agent_end, and REAL
 * talk-back — the hub's {type:"channel"} frames become pi.sendUserMessage.
 *
 * Fail-open everywhere: no daemon (no ~/.antiphon/antiphond.json) means the
 * extension is silently inert; every handler and network op is try/caught;
 * nothing here may ever break the host agent. Zero dependencies — builtin
 * WebSocket + node builtins only.
 */
import { readFileSync } from "node:fs"
import { homedir } from "node:os"
import { join, basename } from "node:path"
import { execSync } from "node:child_process"
import { createHash } from "node:crypto"

const STATE = process.env.ANTIPHON_STATE ?? join(homedir(), ".antiphon")

const NARRATION = `Narrate your work into the Antiphon (required): this session is monitored
by ear — the user hears you as a voice in a virtual room. Call antiphon_task once when you
begin something new (one short spoken headline). Call antiphon_progress BEFORE each meaningful
step — one short, plain, spoken sentence, every time you switch activity; conversational, no
file paths or code. Call antiphon_done when the task is complete (a TWO-sentence spoken summary
of what you did and the outcome). Call antiphon_blocked when you need the user (one clear
question). Do your normal work as usual and don't mention these calls in your text replies —
the narration is the audio channel. Messages arriving in <channel source="antiphon"> tags are
the user speaking to you from the room; treat them as user input.`

// hubUrl resolves the /agent WebSocket URL, or null when the daemon isn't
// running: $ANTIPHON_HUB wins, else the discovery file (whose pid must be alive).
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

// detectInput mirrors antiphond/internal/input.Detect (tmux/cy talk-back target).
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

function spoken(text: string, max = 400): string {
  const t = String(text).replace(/```[\s\S]*?```/g, " ").replace(/\s+/g, " ").trim()
  if (t.length <= max) return t
  const cut = t.slice(0, max)
  const dot = cut.lastIndexOf(". ")
  return dot > max / 2 ? cut.slice(0, dot + 1) : cut
}

// lastAssistantText digs the final assistant message's text out of an
// agent_end event's messages array (content is a string or content blocks).
function lastAssistantText(messages: unknown): string {
  if (!Array.isArray(messages)) return ""
  for (let i = messages.length - 1; i >= 0; i--) {
    const m = messages[i] as any
    if (m?.role !== "assistant") continue
    const c = m.content
    if (typeof c === "string") return c
    if (Array.isArray(c)) {
      return c
        .filter((b: any) => b?.type === "text" && typeof b.text === "string")
        .map((b: any) => b.text)
        .join(" ")
    }
  }
  return ""
}

const DONE_REPLAY_TTL = 5 * 60 * 1000

// Conn: the session's persistent /agent socket. Hello on every (re)connect,
// capped backoff with jitter, stand-down on close code 4000 (replaced).
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
      ws.onerror = () => {}
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

  // Frames during an outage are dropped except the latest done-summary
  // (buffered depth-one, replayed on reconnect — the line with durable value).
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

export default function antiphon(pi: any) {
  const cwd = ((): string => { try { return process.cwd() } catch { return "" } })()
  const repo = repoName(cwd)
  // Extensions run in-process, so pi's own pid + cwd is a stable session id
  // across /reload (same derivation spirit as `antiphond channel`).
  const session =
    process.env.ANTIPHON_SESSION ??
    `pi-${process.pid}-${createHash("sha256").update(cwd).digest("hex").slice(0, 8)}`

  const hello: Record<string, unknown> = { session, kind: "pi", repo, cwd }
  const input = detectInput()
  if (input) hello.input = input
  const conn = new Conn(hello)
  let doneAt = 0

  // Talk-back: the user's words from the room become a real user message —
  // tagged the way the mandate teaches the model to expect them.
  conn.onChannel = (text) => {
    try { pi.sendUserMessage?.(`<channel source="antiphon">${text}</channel>`) } catch {}
  }

  const narrate = (type: string, text: string) => {
    if (!text) return
    conn.open()
    conn.send(type, spoken(text))
    if (type === "done") doneAt = Date.now()
  }

  try {
    pi.on?.("session_start", async () => { try { conn.open() } catch {} })
    pi.on?.("session_shutdown", async () => { try { conn.close() } catch {} })

    pi.on?.("tool_execution_start", async (ev: any) => {
      try {
        if (String(ev?.toolName ?? ev?.name ?? "").startsWith("antiphon_")) return
        conn.open()
        conn.send("tool")
      } catch {}
    })

    // Done backstop: the room hears a real summary even when the model forgot
    // antiphon_done (skipped when it narrated one in the last 30 s).
    pi.on?.("agent_end", async (ev: any) => {
      try {
        if (Date.now() - doneAt < 30000) return
        const text = lastAssistantText(ev?.messages)
        if (text) { conn.open(); conn.send("done", spoken(text)) }
      } catch {}
    })

    // Inject the narration mandate. Only APPEND to an existing systemPrompt —
    // returning one when the event carries none would replace the host's
    // entire prompt (see README).
    pi.on?.("before_agent_start", async (ev: any) => {
      try {
        if (!hubUrl()) return
        if (typeof ev?.systemPrompt === "string" && ev.systemPrompt) {
          return { systemPrompt: `${ev.systemPrompt}\n\n${NARRATION}` }
        }
      } catch {}
    })
  } catch {}

  const reg = (name: string, type: string, arg: string, desc: string, argDesc: string) => {
    try {
      pi.registerTool?.({
        name,
        description: desc,
        parameters: {
          type: "object",
          properties: { [arg]: { type: "string", description: argDesc } },
          required: [arg],
        },
        // Signature-agnostic: find whichever positional argument carries our
        // parameter. ALWAYS returns ok — hub trouble never surfaces to the model.
        execute: async (...call: any[]) => {
          try {
            const args = call.find((a) => a && typeof a === "object" && typeof a[arg] === "string")
            narrate(type, String(args?.[arg] ?? "").trim())
          } catch {}
          return { content: [{ type: "text", text: "ok" }] }
        },
      })
    } catch {}
  }
  reg("antiphon_task", "task", "headline", "Announce the task you are starting.", "One short headline, spoken aloud.")
  reg("antiphon_progress", "progress", "note", "Report what you are doing right now.", "A few words, present tense.")
  reg("antiphon_done", "done", "summary", "Report that you finished.", "1-2 spoken sentences summarizing the outcome.")
  reg("antiphon_blocked", "blocked", "question", "Ask the user a question you are blocked on.", "One clear question.")

  // Bind eagerly too — session_start may have fired before extension load.
  try { if (hubUrl()) conn.open() } catch {}
}
