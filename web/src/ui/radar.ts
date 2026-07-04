import type { Antiphon } from "../audio/engine";
import { lang } from "../demoI18n";
import { rad, TAU } from "../math";

// Full-bleed top-down antiphon, visually mirroring the native RadarView
// (Radar.swift). Agents are world-anchored dots you can pick up and drag
// anywhere in 2D — the engine follows live (with the audition pulse), so you
// *hear* the dot move. The listener slides within the rings from head
// translation; the facing cone tracks head yaw.

const TEAL = "95,208,197"; // #5fd0c5
const GOLD = "255,206,107"; // #ffce6b
const GRAB_PX = 26; // generous grab radius // mirrors Radar.swift hitTest

function rgb(hex: string): string {
  const v = parseInt(hex.replace("#", ""), 16);
  return `${(v >> 16) & 0xff},${(v >> 8) & 0xff},${v & 0xff}`;
}

/** Compact age — "42s" / "3m" / "2h", localized unit letters (mirrors LAge in
 *  L10n.swift, keyed off the demo's active language). `atMs` is performance.now. */
function fmtAge(atMs: number): string {
  const d = Math.max(0, (performance.now() - atMs) / 1000);
  const [s, m, h] =
    lang === "ru"
      ? ["с", "м", "ч"]
      : lang === "zh-Hans"
        ? ["秒", "分", "时"]
        : lang === "zh-Hant"
          ? ["秒", "分", "時"]
          : ["s", "m", "h"];
  if (d < 60) return `${Math.floor(d)}${s}`;
  if (d < 3600) return `${Math.floor(d / 60)}${m}`;
  return `${Math.floor(d / 3600)}${h}`;
}

export function initRadar(engine: Antiphon, cv: HTMLCanvasElement): void {
  const g = cv.getContext("2d")!;
  let W = 0,
    H = 0; // CSS px (the context is DPR-scaled)

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    W = window.innerWidth;
    H = window.innerHeight;
    cv.style.width = W + "px";
    cv.style.height = H + "px";
    cv.width = Math.floor(W * dpr);
    cv.height = Math.floor(H * dpr);
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
  }
  window.addEventListener("resize", resize);
  resize();

  /** px-per-metre chosen so the default 1.3 m arc sits well inside the window.
   *  // mirrors Radar.swift scale() */
  const scale = () => (Math.min(W, H) * 0.34) / 1.3;

  const toScreen = (x: number, z: number) => {
    const s = scale();
    return { x: W / 2 + x * s, y: H / 2 + z * s };
  };
  const toWorld = (px: number, py: number) => {
    const s = scale();
    return { x: (px - W / 2) / s, z: (py - H / 2) / s };
  };

  /** Nearest visible dot within the grab radius, or -1. */
  function hitTest(px: number, py: number): number {
    let best = -1,
      bd = GRAB_PX;
    for (const i of engine.visibleSeats()) {
      const N = engine.nodes[engine.agents[i].id];
      const q = toScreen(N.posX, N.posZ);
      const d = Math.hypot(q.x - px, q.y - py);
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    return best;
  }

  // ---- drag + hover (Pointer Events: mouse + touch + pen) ------------------
  // The grab affordance: an open hand over a dot, closed while carrying — and
  // hovering a dot spotlights its row in the agent list (the mirror of the
  // list hover lighting the dot up out here). // mirrors Radar.swift
  let dragging = -1;
  let hoverHit = -1; // dot under the cursor (drives the cursor + the spotlight)
  const setCursor = () => {
    cv.style.cursor = dragging >= 0 ? "grabbing" : hoverHit >= 0 ? "grab" : "default";
  };
  const pointerPos = (e: PointerEvent) => {
    const r = cv.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  };
  cv.addEventListener("pointerdown", (e) => {
    const p = pointerPos(e);
    const hit = hitTest(p.x, p.y);
    if (hit < 0) return; // empty press: don't grab dots on the way
    dragging = hit;
    cv.setPointerCapture(e.pointerId);
    engine.dragBegan(hit);
    setCursor();
    e.preventDefault();
  });
  cv.addEventListener("pointermove", (e) => {
    const p = pointerPos(e);
    if (dragging >= 0) {
      const w = toWorld(p.x, p.y);
      engine.dragMoved(dragging, w.x, w.z);
      e.preventDefault();
    } else if (e.pointerType === "mouse") {
      const hit = hitTest(p.x, p.y);
      if (hit !== hoverHit) {
        hoverHit = hit;
        engine.setHovered(hit); // spotlight the list row (bidirectional)
      }
      setCursor();
    }
  });
  cv.addEventListener("pointerleave", () => {
    if (hoverHit >= 0) {
      hoverHit = -1;
      engine.setHovered(-1);
    }
    setCursor();
  });
  const endDrag = () => {
    if (dragging >= 0) engine.dragEnded();
    dragging = -1;
    setCursor();
  };
  cv.addEventListener("pointerup", endDrag);
  cv.addEventListener("pointercancel", endDrag);

  // ---- the hover bubble -----------------------------------------------------
  // Whichever agent is spotlit (from either side) speaks its latest narration
  // line in place, over its dot — with a dim inline age; the title stands in
  // when it hasn't said anything yet (no age then). An absolutely-positioned
  // DOM node so the text engine does the wrapping; pointer-events: none is the
  // allowsHitTesting(false) equivalent. // mirrors HoverBubble in Radar.swift
  const bubble = document.createElement("div");
  bubble.className = "radar-bubble";
  bubble.hidden = true;
  const bubbleText = document.createElement("span");
  bubbleText.className = "bubble-text";
  bubble.appendChild(bubbleText);
  (cv.parentElement ?? document.body).appendChild(bubble);
  let bubbleKey = ""; // seat|text|age — only touch the DOM when it changes

  function updateBubble(): void {
    const seat = engine.hoveredSeat;
    let text = "",
      age = "",
      color = "",
      anchor: { x: number; y: number } | null = null;
    if (dragging < 0 && seat >= 0) {
      const a = engine.agents[seat];
      const N = a ? engine.nodes[a.id] : null;
      if (N && N.present && !N.snoozed) {
        const title = N.meta.title || (engine.mode === "demo" ? a.task : "");
        text = N.lastLine || title;
        age = N.lastLine && N.lastAt ? fmtAge(N.lastAt) : "";
        color = a.color;
        anchor = toScreen(N.posX, N.posZ);
      }
    }
    if (!text || !anchor) {
      bubble.hidden = true;
      bubbleKey = "";
      return;
    }
    const key = `${seat}|${text}|${age}`;
    if (key !== bubbleKey) {
      bubbleKey = key;
      bubbleText.textContent = text;
      if (age) {
        // the dim inline age suffix rides inside the same 3-line clamp
        bubbleText.textContent = text + " ";
        const span = document.createElement("span");
        span.className = "bubble-age";
        span.textContent = age;
        bubbleText.appendChild(span);
      }
      bubble.style.borderColor = `rgba(${rgb(color)},0.35)`;
    }
    bubble.hidden = false;
    // Position from the MEASURED size (mirrors Radar.swift bubblePosition):
    // prefer floating above the dot; flip below near the top; clamp inside the
    // viewport on all edges and never slide under the agent-list rail.
    const r = bubble.getBoundingClientRect();
    const m = 10,
      clearance = 22;
    const halfW = r.width / 2,
      halfH = r.height / 2;
    let rightEdge = W - m;
    const list = document.getElementById("agentList");
    if (list && !list.hidden) {
      const lr = list.getBoundingClientRect();
      // the desktop right rail constrains x; the phone bottom sheet (full
      // width) doesn't
      if (lr.width < W - 40) rightEdge = Math.min(rightEdge, lr.left - 12);
    }
    const x = Math.min(Math.max(anchor.x, m + halfW), Math.max(m + halfW, rightEdge - halfW));
    let y = anchor.y - clearance - halfH;
    if (y - halfH < m) y = anchor.y + clearance + halfH; // flip below the dot
    y = Math.min(Math.max(y, m + halfH), H - m - halfH);
    bubble.style.left = (x - halfW).toFixed(1) + "px";
    bubble.style.top = (y - halfH).toFixed(1) + "px";
  }

  // ---- draw -----------------------------------------------------------------
  function draw() {
    engine.tick();
    const cx = W / 2,
      cy = H / 2,
      s = scale();
    g.clearRect(0, 0, W, H);
    const dim = 0.4 + 0.6 * engine.lookGate;

    // listener slides with head translation, world-anchored dots stay put
    const hp = engine.headPos;
    const lim = 1.0 * s;
    const lcx = cx + Math.max(-lim, Math.min(lim, hp.x * s));
    const lcy = cy + Math.max(-lim, Math.min(lim, hp.z * s));

    // The Antiphon eye, monochrome (mirrors native RadarView): inner disc,
    // thick iris band, bold ring, hairline outer rings. World-anchored on
    // the calibrated neutral — the pupil (you) drifts inside it.
    const ring = (r: number, alpha: number, width = 1) => {
      g.beginPath();
      g.arc(cx, cy, r, 0, TAU);
      g.strokeStyle = `rgba(255,255,255,${alpha})`;
      g.lineWidth = width;
      g.stroke();
    };
    // kept just above the threshold of noticing — texture, not a boundary
    g.beginPath();
    g.arc(cx, cy, 0.5 * s, 0, TAU);
    g.fillStyle = "rgba(255,255,255,0.02)";
    g.fill();
    ring(0.72 * s, 0.03, 0.26 * s); // the iris band
    ring(0.95 * s, 0.07, 1.5); // the bold ring
    ring(1.3 * s, 0.03); // hairline, agents' arc
    ring(1.62 * s, 0.022); // outermost hairline

    // facing cone (emanates from the listener's current position)
    g.beginPath();
    g.moveTo(lcx, lcy);
    g.arc(
      lcx,
      lcy,
      s * 1.3 * 1.15,
      -Math.PI / 2 - rad(26) + engine.orient,
      -Math.PI / 2 + rad(26) + engine.orient,
    );
    g.closePath();
    g.fillStyle = `rgba(${TEAL},${0.13 * dim})`;
    g.fill();

    // the pupil: you, glint and all
    g.beginPath();
    g.arc(lcx, lcy, 9, 0, TAU);
    g.fillStyle = "#fff";
    g.fill();
    g.beginPath();
    g.arc(lcx - 9 * 0.42, lcy - 9 * 0.42, 2.4, 0, TAU);
    g.fillStyle = "#0a0c10";
    g.fill();

    const facedId = engine.facedAgent()?.id ?? null;
    const now = performance.now();

    for (const i of engine.visibleSeats()) {
      const a = engine.agents[i];
      const N = engine.nodes[a.id];
      const p = toScreen(N.posX, N.posZ);
      const faced = a.id === facedId;
      const hovered = i === engine.hoveredSeat;
      const dragged = i === dragging;
      const baseR = dragged ? 11 : faced || hovered ? 9 : 7;

      // ping ripples (done)
      if (N.state === "done" && N.lastPingMs) {
        const age = (now - N.lastPingMs) / 900;
        if (age >= 0 && age < 1) {
          g.beginPath();
          g.arc(p.x, p.y, baseR + age * s * 1.3 * 0.18, 0, TAU);
          g.strokeStyle = `rgba(${GOLD},${0.5 * (1 - age)})`;
          g.lineWidth = 2;
          g.stroke();
        }
      }

      // hover halo: the list row under the cursor shows itself here
      if (hovered || dragged) {
        g.beginPath();
        g.arc(p.x, p.y, baseR + 7, 0, TAU);
        g.fillStyle = `rgba(${rgb(a.color)},0.22)`;
        g.fill();
      }

      // body dot
      const alpha = (N.state === "heard" ? 0.4 : faced ? 1 : 0.85) * dim;
      g.beginPath();
      g.arc(p.x, p.y, baseR, 0, TAU);
      g.fillStyle = `rgba(${rgb(a.color)},${alpha})`;
      g.fill();

      if (N.state === "done") {
        g.lineWidth = 2.5;
        g.strokeStyle = "#ffce6b";
        g.stroke();
      } else if (N.state === "summarizing") {
        g.lineWidth = 2.5;
        g.strokeStyle = "#5fd0c5";
        g.stroke();
      } else if (faced) {
        g.lineWidth = 3;
        g.strokeStyle = "#5fd0c5";
        g.stroke();
      }
      if (hovered || dragged) {
        g.lineWidth = 1.5;
        g.strokeStyle = "rgba(255,255,255,0.85)";
        g.stroke();
      }
    }
    updateBubble(); // dots move (drag/rearrange) — the bubble follows per frame
    requestAnimationFrame(draw);
  }
  requestAnimationFrame(draw);
}
