/**
 * Chamber hub — the shared local router. One per machine. It connects the per-session
 * channel subprocesses (cc-chamber/chamber-channel.ts) to the voice-chamber page:
 *
 *   • /agent  (WS) — each Claude session's channel subprocess connects here. The hub
 *     claims it a seat, relays its narration (task/progress/done/blocked) to the page
 *     (synthesizing audio on the way), and routes the user's typed messages back to it.
 *   • /stream (WS) — the page connects here. It receives narration frames (with inline
 *     audio) and sends `say` messages aimed at the seat the user is facing.
 *   • /debug/emit (POST) — drive the page directly, no session needed (see mock.ts).
 *
 * The hub owns the ElevenLabs key (via .env) so it never reaches the browser. The MCP
 * protocol itself now lives in the subprocess; the hub speaks plain JSON over WebSocket.
 * Run from the repo root so Bun loads .env. Zero hand-rolled protocol.
 */
import type { ServerWebSocket } from "bun";
import { ROSTER } from "./roster";
import { FLASH, QUALITY, synth } from "./tts";

type WSData = { kind: "page" } | { kind: "agent"; seat: number };

const PORT = Number(process.env.CHAMBER_PORT || 8787);

const pages = new Set<ServerWebSocket<WSData>>();
const agentBySeat = new Map<number, ServerWebSocket<WSData>>();
const takenSeats = new Set<number>();

const CORS: Record<string, string> = {
  "access-control-allow-origin": "*",
  "access-control-allow-headers": "*",
  "access-control-allow-methods": "*",
};

function claimSeat(): number {
  let i = 0;
  while (i < ROSTER.length && takenSeats.has(i)) i++;
  if (i >= ROSTER.length) i = ROSTER.length - 1; // overflow: pile onto the last seat
  takenSeats.add(i);
  return i;
}

function broadcast(frame: unknown): void {
  const msg = JSON.stringify(frame);
  for (const ws of pages) {
    try {
      ws.send(msg);
    } catch {
      /* dropped */
    }
  }
}

// narration type -> the text field its frame carries
const FIELD: Record<string, string> = {
  task: "headline",
  progress: "note",
  done: "summary",
  blocked: "question",
};

/** Synthesize (if there's text) and push a narration frame to every page. */
async function emit(seatIdx: number, type: string, text?: string): Promise<void> {
  const seat = ROSTER[seatIdx];
  if (!seat) return;
  if (type === "bind") {
    broadcast({ type: "bind", seat: seatIdx, color: seat.color });
    return;
  }
  if (type === "free") {
    broadcast({ type: "free", seat: seatIdx });
    return;
  }
  const frame: Record<string, unknown> = { type, seat: seatIdx, color: seat.color };
  const field = FIELD[type];
  if (text != null && field) frame[field] = text;
  if (text) {
    const model = type === "progress" ? FLASH : QUALITY;
    const bytes = await synth(seat.voice, text, model);
    if (bytes) frame.audioB64 = Buffer.from(bytes).toString("base64");
  }
  broadcast(frame);
  const preview = text ? ` ${JSON.stringify(text.slice(0, 56))}` : "";
  console.log(`[chamber] seat=${seatIdx} ${type}${preview}`);
}

Bun.serve<WSData, undefined>({
  port: PORT,
  hostname: "127.0.0.1",
  idleTimeout: 0, // never drop the long-lived agent/page sockets
  async fetch(req, server) {
    const url = new URL(req.url);
    if (req.method === "OPTIONS") return new Response(null, { headers: CORS });

    if (url.pathname === "/stream") {
      if (server.upgrade(req, { data: { kind: "page" } })) return undefined;
      return new Response("expected websocket", { status: 400, headers: CORS });
    }
    if (url.pathname === "/agent") {
      if (server.upgrade(req, { data: { kind: "agent", seat: -1 } })) return undefined;
      return new Response("expected websocket", { status: 400, headers: CORS });
    }
    if (url.pathname === "/health") {
      return Response.json({ ok: true, agents: [...agentBySeat.keys()] }, { headers: CORS });
    }
    if (url.pathname === "/debug/emit" && req.method === "POST") {
      const b = (await req.json().catch(() => null)) as
        | { seat?: number; type?: string; text?: string }
        | null;
      if (!b || !b.type) return new Response("bad request", { status: 400, headers: CORS });
      void emit(b.seat ?? 0, b.type, b.text);
      return Response.json({ ok: true }, { headers: CORS });
    }
    return new Response("chamber hub", { headers: CORS });
  },
  websocket: {
    open(ws) {
      if (ws.data.kind === "agent") {
        const seat = claimSeat();
        ws.data.seat = seat;
        agentBySeat.set(seat, ws);
        ws.send(JSON.stringify({ type: "seat", seat, color: ROSTER[seat].color }));
        void emit(seat, "bind");
        console.log(`[chamber] agent connected -> seat ${seat}`);
      } else {
        pages.add(ws);
        ws.send(
          JSON.stringify({
            type: "hello",
            seats: ROSTER.map((r, i) => ({ seat: i, color: r.color })),
          }),
        );
      }
    },
    message(ws, raw) {
      let m: { type?: string; seat?: number; text?: string };
      try {
        m = JSON.parse(String(raw));
      } catch {
        return;
      }
      if (ws.data.kind === "agent") {
        // narration from a session → relay to the page
        if (m.type && FIELD[m.type]) void emit(ws.data.seat, m.type, m.text);
      } else if (m.type === "say" && typeof m.seat === "number" && m.text) {
        // the user spoke to the seat they're facing → route to that subprocess
        const target = agentBySeat.get(m.seat);
        if (target) {
          try {
            target.send(JSON.stringify({ type: "channel", text: String(m.text) }));
            console.log(`[chamber] say -> seat ${m.seat}: ${JSON.stringify(String(m.text).slice(0, 56))}`);
          } catch {
            /* dropped */
          }
        } else {
          console.log(`[chamber] say -> seat ${m.seat} but no session is connected there`);
        }
      }
    },
    close(ws) {
      if (ws.data.kind === "agent") {
        const seat = ws.data.seat;
        if (seat >= 0) {
          takenSeats.delete(seat);
          agentBySeat.delete(seat);
          void emit(seat, "free");
          console.log(`[chamber] agent seat ${seat} disconnected`);
        }
      } else {
        pages.delete(ws);
      }
    },
  },
});

console.log(`[chamber] hub listening on http://127.0.0.1:${PORT}`);
console.log(`[chamber]   agents: ws://127.0.0.1:${PORT}/agent   (session subprocesses)`);
console.log(`[chamber]   page:   ws://127.0.0.1:${PORT}/stream  (the browser)`);
console.log(`[chamber]   debug:  POST /debug/emit {seat,type,text}`);
