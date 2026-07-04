// The "close your eyes" workflow demo — the site's key moment. NOT a video:
// a DOM/canvas-rendered run of the real workflow, synchronized to a soundtrack
// rendered OFFLINE by the actual engine (tools/gen-hero-audio.py →
// /hero-demo.m4a + hero-timeline.json). One clock drives everything: the
// audio element when sound is on, a monotonic clock when muted — so the
// unmute button just re-anchors to audio.currentTime and nothing drifts.
//
// Scene: an imaginary desktop (with a visible head/eye-tracking card) → the
// user closes their eyes (lids) → the app's radar world → the gaze sweeps to
// agent A (accept chime, spoken summary), then to B → eyes open → the
// talk-back letter → a typed reply → Enter. Then a replay affordance.

import "./hero.css";
import timeline from "./hero-timeline.json";

type AgentKey = "A" | "B";
const T = timeline.t;
const AG = timeline.agents as Record<
  AgentKey,
  { name: string; color: string; bearingDeg: number; distance: number }
>;

// app radar palette (mirrors native RadarView)
const BG = "#0a0c10";
const TEAL = "#5fd0c5";
const GOLD = "#ffce6b";

const rad = (d: number) => (d * Math.PI) / 180;
const TAU = Math.PI * 2;

// the gaze keyframes — same shape the audio generator rendered with
const POSE: [number, number][] = [
  [0, 0],
  [T.gazeA, 0],
  [T.gazeA + 0.9, AG.A.bearingDeg],
  [T.gazeB, AG.A.bearingDeg],
  [T.gazeB + 0.9, AG.B.bearingDeg],
  [T.eyesOpen, AG.B.bearingDeg],
  [T.eyesOpen + 1, 0],
];
function yawAt(t: number): number {
  if (t <= POSE[0][0]) return rad(POSE[0][1]);
  for (let i = 0; i < POSE.length - 1; i++) {
    const [t0, y0] = POSE[i];
    const [t1, y1] = POSE[i + 1];
    if (t >= t0 && t <= t1) {
      const u = t1 > t0 ? (t - t0) / (t1 - t0) : 1;
      const s = u * u * (3 - 2 * u);
      return rad(y0 + (y1 - y0) * s);
    }
  }
  return rad(POSE[POSE.length - 1][1]);
}

// ping moments (match gen-hero-audio.py)
const PINGS: { agent: AgentKey; t: number }[] = [
  { agent: "A", t: T.worldIn + 0.2 },
  { agent: "A", t: T.worldIn + 2.8 },
  { agent: "B", t: T.pingB },
];

const html = String.raw;

export function mountHero(el: HTMLElement | null): void {
  if (!el) return;
  el.innerHTML = html`
    <div class="hx-layer hx-desk" data-hx="desk">
      <div class="hx-desk-bar"><i></i><i></i><i></i></div>
      <div class="hx-win" style="left:6%;top:16%;width:44%;height:64%">
        <div class="hx-codeline"></div><div class="hx-codeline c2"></div>
        <div class="hx-codeline c3"></div><div class="hx-codeline c4"></div>
        <div class="hx-codeline"></div><div class="hx-codeline c2"></div>
      </div>
      <div class="hx-win" style="right:7%;top:30%;width:38%;height:54%">
        <div class="hx-codeline c3"></div><div class="hx-codeline"></div>
        <div class="hx-codeline c4"></div><div class="hx-codeline c2"></div>
      </div>
      <div class="hx-cam" data-hx="cam">
        <svg width="66" height="50" viewBox="0 0 66 50">
          <g class="hx-cam-face">
            <ellipse cx="33" cy="26" rx="15" ry="18" fill="none"
              stroke="rgba(246,239,226,0.4)" stroke-width="1.2" />
            <g data-hx="eyesOpen">
              <circle cx="27" cy="22" r="2.2" fill="#7D93E8" />
              <circle cx="39" cy="22" r="2.2" fill="#7D93E8" />
            </g>
            <g data-hx="eyesShut" opacity="0">
              <path d="M24.5 22 h5" stroke="#7D93E8" stroke-width="1.6" />
              <path d="M36.5 22 h5" stroke="#7D93E8" stroke-width="1.6" />
            </g>
            <circle cx="33" cy="30" r="1.4" fill="rgba(246,239,226,0.5)" />
          </g>
        </svg>
        <div class="hx-cam-label">
          <b><span class="hx-cam-dot"></span><span data-hx="camState">watching</span></b>
          head &amp; eyes tracked
        </div>
      </div>
    </div>

    <div class="hx-layer hx-world" data-hx="world" style="opacity:0">
      <canvas data-hx="canvas"></canvas>
      <div class="hx-hint">the room, from above — voices stay put as you turn</div>
      <div class="hx-cap" data-hx="capA">“${timeline.captions.summary_A}”</div>
      <div class="hx-cap" data-hx="capB">“${timeline.captions.summary_B}”</div>
    </div>

    <div class="hx-layer hx-idle" data-hx="idle">
      <svg width="64" height="40" viewBox="0 0 64 40">
        <path d="M2 20 Q32 -10 62 20 Q32 50 2 20 Z" fill="none" stroke="#2743B8" stroke-width="2" />
        <circle cx="32" cy="20" r="9" fill="#2743B8" />
        <circle cx="29" cy="17" r="2.5" fill="#F4EDE2" />
      </svg>
      <div class="hx-idle-title">Put on headphones.</div>
      <button class="hx-idle-btn" data-hx="begin">Close your eyes&nbsp;↵</button>
      <div class="hx-idle-note">The real workflow, in half a minute · rendered by the real engine · sound on</div>
    </div>

    <div class="hx-lid top" data-hx="lidT"></div>
    <div class="hx-lid bottom" data-hx="lidB"></div>

    <!-- the letter belongs to the agent being answered — B, the docs agent -->
    <div class="hx-letter" data-hx="letter">
      <div class="hx-letter-head">
        <span class="hx-letter-dot" style="background:${AG.B.color};box-shadow:0 0 8px ${AG.B.color}"></span>
        <span class="hx-letter-name">${AG.B.name}</span>
        <span class="hx-letter-kind">Claude Code</span>
      </div>
      <div class="hx-letter-line"><b>DONE</b><span>${timeline.captions.summary_B}</span></div>
      <div class="hx-letter-input" data-hx="input"><span data-hx="typed"></span><span class="hx-caret"></span></div>
    </div>

    <button class="hx-sound" data-hx="sound" hidden>🔇 unmute</button>
    <button class="hx-replay" data-hx="replay">replay ⟳</button>
  `;

  const $ = <E extends HTMLElement = HTMLElement>(k: string) =>
    el.querySelector(`[data-hx="${k}"]`) as E;
  const desk = $("desk");
  const idle = $("idle");
  const world = $("world");
  const canvas = $<HTMLCanvasElement>("canvas");
  const g = canvas.getContext("2d")!;
  const capEls = { A: $("capA"), B: $("capB") };
  const letter = $("letter");
  const typed = $("typed");
  const input = $("input");
  const soundBtn = $<HTMLButtonElement>("sound");
  const replayBtn = $<HTMLButtonElement>("replay");
  const camState = $("camState");
  const eyesOpenG = el.querySelector('[data-hx="eyesOpen"]') as SVGGElement;
  const eyesShutG = el.querySelector('[data-hx="eyesShut"]') as SVGGElement;

  const audio = new Audio("/hero-demo.m4a");
  audio.preload = "auto";

  let running = false;
  let muted = false;
  let clock0 = 0; // performance.now anchor while muted
  let raf = 0;

  const now = () => (muted ? (performance.now() - clock0) / 1000 : audio.currentTime);

  function setLids(closed: boolean) {
    el!.classList.toggle("hx-lids-closed", closed);
  }

  function begin(withSound: boolean) {
    muted = !withSound;
    running = true;
    replayBtn.classList.remove("on");
    soundBtn.hidden = false;
    soundBtn.textContent = muted ? "🔇 unmute" : "🔊 sound on";
    letter.classList.remove("on");
    input.classList.remove("sent");
    typed.textContent = "";
    idle.style.opacity = "0";
    idle.style.pointerEvents = "none";
    if (withSound) {
      audio.currentTime = 0;
      audio.play().catch(() => {
        // autoplay refused → run on the muted clock; the button recovers sound
        muted = true;
        clock0 = performance.now();
        soundBtn.textContent = "🔇 unmute";
      });
    } else {
      clock0 = performance.now();
    }
    cancelAnimationFrame(raf);
    raf = requestAnimationFrame(frame);
  }

  function finish() {
    running = false;
    setLids(false);
    world.style.opacity = "0";
    desk.style.opacity = "1";
    replayBtn.classList.add("on");
    soundBtn.hidden = true;
    if (!muted) audio.pause();
  }

  soundBtn.addEventListener("click", () => {
    if (!running) return;
    if (muted) {
      audio.currentTime = Math.min(now(), timeline.duration - 0.05);
      void audio.play();
      muted = false;
      soundBtn.textContent = "🔊 sound on";
    } else {
      clock0 = performance.now() - now() * 1000;
      audio.pause();
      muted = true;
      soundBtn.textContent = "🔇 unmute";
    }
  });
  $("begin").addEventListener("click", () => begin(true));
  replayBtn.addEventListener("click", () => begin(!muted));

  // ---- the radar world, drawn with the app's geometry ------------------------
  function drawWorld(t: number) {
    const rect = canvas.getBoundingClientRect();
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    if (canvas.width !== Math.round(rect.width * dpr)) {
      canvas.width = Math.round(rect.width * dpr);
      canvas.height = Math.round(rect.height * dpr);
    }
    g.setTransform(dpr, 0, 0, dpr, 0, 0);
    const W = rect.width;
    const H = rect.height;
    g.clearRect(0, 0, W, H);
    const cx = W / 2;
    const cy = H / 2 + 14;
    const s = (Math.min(W, H) * 0.36) / 1.3;
    const yaw = yawAt(t);

    const ring = (r: number, alpha: number, width = 1) => {
      g.beginPath();
      g.arc(cx, cy, r, 0, TAU);
      g.strokeStyle = `rgba(255,255,255,${alpha})`;
      g.lineWidth = width;
      g.stroke();
    };
    // the Antiphon eye, at the app's texture level
    g.beginPath();
    g.arc(cx, cy, 0.5 * s, 0, TAU);
    g.fillStyle = "rgba(255,255,255,0.02)";
    g.fill();
    ring(0.72 * s, 0.03, 0.26 * s);
    ring(0.95 * s, 0.07, 1.5);
    ring(1.3 * s, 0.03);

    // facing cone
    g.beginPath();
    g.moveTo(cx, cy);
    g.arc(cx, cy, s * 1.5, -Math.PI / 2 - rad(26) + yaw, -Math.PI / 2 + rad(26) + yaw);
    g.closePath();
    g.fillStyle = "rgba(95,208,197,0.13)";
    g.fill();

    // the pupil (you)
    g.beginPath();
    g.arc(cx, cy, 8, 0, TAU);
    g.fillStyle = "#fff";
    g.fill();
    g.beginPath();
    g.arc(cx - 3.2, cy - 3.2, 2.1, 0, TAU);
    g.fillStyle = BG;
    g.fill();

    for (const key of ["A", "B"] as AgentKey[]) {
      const a = AG[key];
      const b = rad(a.bearingDeg);
      const px = cx + Math.sin(b) * a.distance * s;
      const py = cy - Math.cos(b) * a.distance * s;

      // done state begins at the first ping; B works (dim pulse) before its ping
      const firstPing = PINGS.find((p) => p.agent === key)!.t;
      const done = t >= firstPing - 0.05;
      const lineStart = key === "A" ? T.lineA : T.lineB;
      const lineEnd = key === "A" ? T.lineAEnd : T.lineBEnd;
      const speaking = t >= lineStart - 0.4 && t <= lineEnd + 0.2;
      const heard = t > lineEnd + 0.2;

      // ping ripples
      for (const p of PINGS) {
        if (p.agent !== key) continue;
        const age = (t - p.t) / 0.9;
        if (age >= 0 && age < 1) {
          const rr = 7 + age * s * 0.24;
          g.beginPath();
          g.arc(px, py, rr, 0, TAU);
          g.strokeStyle = `rgba(255,206,107,${0.5 * (1 - age)})`;
          g.lineWidth = 2;
          g.stroke();
        }
      }

      const R = speaking ? 9 : 7;
      g.beginPath();
      g.arc(px, py, R, 0, TAU);
      g.globalAlpha = heard && !speaking ? 0.45 : 1;
      g.fillStyle = a.color;
      g.fill();
      g.globalAlpha = 1;
      if (speaking) {
        g.beginPath();
        g.arc(px, py, R, 0, TAU);
        g.strokeStyle = TEAL;
        g.lineWidth = 2.5;
        g.stroke();
      } else if (done && !heard) {
        g.beginPath();
        g.arc(px, py, R, 0, TAU);
        g.strokeStyle = GOLD;
        g.lineWidth = 2.5;
        g.stroke();
      }

      // caption placement near the dot
      const cap = capEls[key];
      cap.style.left = `${px}px`;
      cap.style.top = `${py + 18}px`;
      cap.style.opacity = speaking ? "1" : "0";
    }
  }

  // ---- the frame loop ---------------------------------------------------------
  function frame() {
    if (!running) return;
    const t = now();

    // desktop ↔ world layering
    const lidsClosed = t >= T.eyesClose + 0.2 && t < T.worldIn + 0.25;
    setLids(lidsClosed);
    const inWorld = t >= T.worldIn && t < T.eyesOpen + 0.4;
    world.style.opacity = inWorld ? "1" : "0";
    desk.style.opacity = inWorld ? "0" : "1";

    // the tracking card mirrors the imaginary user
    const shut = t >= T.eyesClose && t < T.eyesOpen;
    eyesOpenG.setAttribute("opacity", shut ? "0" : "1");
    eyesShutG.setAttribute("opacity", shut ? "1" : "0");
    camState.textContent = shut ? "eyes closed" : "watching";

    if (inWorld) drawWorld(t);

    // the letter, after the eyes open
    if (t >= T.letterIn && t < T.send + 0.5) {
      letter.classList.add("on");
      const chars = Math.max(
        0,
        Math.floor(((t - T.typeStart) / (T.typeEnd - T.typeStart)) * timeline.reply.length),
      );
      typed.textContent = timeline.reply.slice(0, Math.min(chars, timeline.reply.length));
      if (t >= T.send) input.classList.add("sent");
    } else if (t >= T.send + 0.5) {
      letter.classList.remove("on");
    }

    if (t >= timeline.duration - 0.05) {
      finish();
      return;
    }
    raf = requestAnimationFrame(frame);
  }
}
