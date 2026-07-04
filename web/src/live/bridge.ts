import type { Antiphon } from "../audio/engine";
import { D } from "../demoI18n";

/**
 * Live mode: connect to the local antiphon bridge and translate its frames into engine
 * calls. The bridge does identity (seat per session), narration content, and TTS; the
 * page just plays it spatially. Used only when the app is opened with `?live` against a
 * bridge running on the same machine (see docs/cc-integration-plan.md).
 */
const BRIDGE_HTTP = "http://127.0.0.1:8787";
const BRIDGE_WS = "ws://127.0.0.1:8787/stream";

/** One /stream frame (superset of all types — mirrors Frame in BridgeClient.swift). */
interface Frame {
  type: "hello" | "bind" | "tool" | "task" | "progress" | "done" | "blocked" | "free";
  seat: number;
  agent?: string;
  name?: string;
  kind?: string;
  title?: string;
  input?: string;
  color?: string;
  headline?: string;
  note?: string;
  summary?: string;
  question?: string;
  audioB64?: string;
  audioUrl?: string;
}

/** The narration text a frame carries, by type (mirrors the hub's FIELD map). */
function frameText(f: Frame): string | undefined {
  switch (f.type) {
    case "task":
      return f.headline;
    case "progress":
      return f.note;
    case "done":
      return f.summary;
    case "blocked":
      return f.question;
    default:
      return undefined;
  }
}

function b64ToBuffer(b64: string): ArrayBuffer {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes.buffer;
}

/** Prefer fetching the cached line over the inline base64 — smaller frames, no
 *  message-size cliffs, same bytes (localhost). // mirrors BridgeClient.handle */
async function frameAudio(f: Frame): Promise<ArrayBuffer | null> {
  if (f.audioUrl) {
    try {
      const r = await fetch(BRIDGE_HTTP + f.audioUrl);
      if (r.ok) return await r.arrayBuffer();
    } catch {
      /* fall through to the inline copy */
    }
  }
  return f.audioB64 ? b64ToBuffer(f.audioB64) : null;
}

export function connectLive(engine: Antiphon): void {
  engine.startLive();

  let socket: WebSocket | null = null;
  const send = (obj: unknown) => {
    if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(obj));
  };
  wireInput(engine, send);

  let retry = 0;
  const open = () => {
    const ws = new WebSocket(BRIDGE_WS);
    socket = ws;

    ws.onopen = () => {
      retry = 0;
      console.info("[antiphon] bridge connected");
    };
    ws.onerror = () => ws.close();
    ws.onclose = () => {
      retry = Math.min(retry + 1, 6);
      setTimeout(open, 500 * retry);
    };

    ws.onmessage = async (e) => {
      let f: Frame;
      try {
        f = JSON.parse(e.data as string);
      } catch {
        return;
      }
      switch (f.type) {
        case "bind":
          engine.bindSeat(f.seat, {
            agent: f.agent,
            name: f.name,
            kind: f.kind,
            title: f.title,
            input: f.input,
          });
          break;
        case "tool":
          // no audio, no text — just the next descending chord note + sign of life
          engine.bridgeTool(f.seat);
          break;
        case "task":
        case "progress":
        case "blocked":
        case "done": {
          const text = frameText(f);
          if (text) engine.bridgeLine(f.seat, f.type, text); // list line + lastActivity
          if (f.type === "task") engine.setTask(f.seat, f.headline ?? "");
          const audio = await frameAudio(f);
          if (f.type === "done") {
            if (audio) engine.setSummaryClip(f.seat, await engine.decodeBytes(audio));
            engine.markDone(f.seat);
          } else if (audio) {
            engine.enqueueProgress(f.seat, await engine.decodeBytes(audio));
          }
          break;
        }
        case "free":
          engine.unbindSeat(f.seat);
          break;
        // "hello" — initial seat/color list; ignored (engine owns its own roster)
      }
    };
  };
  open();
}

/**
 * The talk-back input: face an agent, focus the field (which LOCKS onto that agent so
 * head-drift while you dictate doesn't change the target), type or dictate, press Enter.
 * The field tints with the target agent's color. Unfocused, it tracks whoever you face.
 */
function wireInput(engine: Antiphon, send: (obj: unknown) => void): void {
  const form = document.getElementById("say") as HTMLFormElement | null;
  const input = document.getElementById("sayText") as HTMLInputElement | null;
  if (!form || !input) return;
  form.hidden = false;

  let locked = -1; // seat captured at focus; -1 when not focused

  const tint = (seat: number) => {
    input.style.borderColor = seat >= 0 ? engine.agents[seat].color : "";
    input.placeholder =
      seat >= 0 ? D.sayPlaceholderSeat : D.sayPlaceholder;
  };

  // while not composing, follow whoever you're facing
  const prev = engine.onOrient;
  engine.onOrient = (deg) => {
    prev(deg);
    if (locked < 0) tint(engine.facedIndex());
  };
  tint(engine.facedIndex());

  input.addEventListener("focus", () => {
    locked = engine.facedIndex();
    tint(locked);
  });
  input.addEventListener("blur", () => {
    locked = -1;
    tint(engine.facedIndex());
  });

  form.addEventListener("submit", (e) => {
    e.preventDefault();
    const text = input.value.trim();
    const seat = locked >= 0 ? locked : engine.facedIndex();
    if (!text || seat < 0) return;
    send({ type: "say", seat, text });
    input.value = "";
  });
}
