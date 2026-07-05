// The hero workflow demo — the site's key moment. NOT a video: a DOM/canvas
// rendered run of the real workflow, synchronized to a soundtrack rendered
// OFFLINE by the actual engine (tools/gen-hero-audio.py → /hero-demo.<lang>.m4a
// + hero-timeline.<lang>.json, one per language — the timings differ because
// the spoken lines do).
//
// It AUTOPLAYS muted and loops; the only control is the sound pill. One
// virtual clock drives everything: t < INTRO is a short silent beat on the
// desktop before the narration starts; audio-time zero is at t = INTRO.
// Muted, the clock is monotonic; with sound on it re-anchors to
// audio.currentTime + INTRO so nothing drifts.
//
// Scene: the imaginary desktop, with a FaceTime-style PiP of the user's face
// (landmark mesh, eye state) that persists throughout → the eyes close (lids)
// → the app's radar world, the PiP head turning as the gaze sweeps to agent A
// then B → eyes open → the talk-back letter → a typed reply → Enter → loop.

import "./hero.css";
import tlEn from "./hero-timeline.en.json";
import tlRu from "./hero-timeline.ru.json";
import tlHans from "./hero-timeline.zh-Hans.json";
import tlHant from "./hero-timeline.zh-Hant.json";
import type { Lang, HeroStrings } from "./i18n";

type AgentKey = "A" | "B";

interface Timeline {
  duration: number;
  agents: Record<AgentKey, { name: string; color: string; bearingDeg: number; distance: number }>;
  captions: { working_A: string; summary_B: string };
  reply: string;
  ticksA: number[];
  t: Record<string, number>;
}

const TIMELINES: Record<Lang, Timeline> = {
  en: tlEn as unknown as Timeline,
  ru: tlRu as unknown as Timeline,
  "zh-Hans": tlHans as unknown as Timeline,
  "zh-Hant": tlHant as unknown as Timeline,
};

// app radar palette (mirrors native RadarView)
const BG = "#0a0c10";
const TEAL = "#5fd0c5";
const GOLD = "#ffce6b";
const TERRA = "#C4694A";
const PERI = "#7D93E8";

// the silent opening beat on the desktop, in seconds before audio zero
const INTRO = 1.2;
const PIP_IN = 0.45;
const LOOP_GAP = 1.6; // silent tail after the audio before the loop restarts

const rad = (d: number) => (d * Math.PI) / 180;
const TAU = Math.PI * 2;

const html = String.raw;

// the industry-standard speaker: slashed when muted, waves when live
const soundIcon = (muted: boolean) => muted
  ? html`<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor"
      stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d="M11 5 6.5 9H3v6h3.5L11 19z" fill="currentColor" stroke="none" />
      <line x1="22" y1="9" x2="16" y2="15" />
      <line x1="16" y1="9" x2="22" y2="15" />
    </svg>`
  : html`<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor"
      stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
      <path d="M11 5 6.5 9H3v6h3.5L11 19z" fill="currentColor" stroke="none" />
      <path d="M15.5 8.5a5 5 0 0 1 0 7" />
      <path d="M18.5 5.5a9.5 9.5 0 0 1 0 13" />
    </svg>`;

// the FaceTime-style PiP face tile
const pipSvg = html`
  <svg viewBox="0 0 104 96" aria-hidden="true">
    <rect width="104" height="96" fill="#12100e" />
    <g class="hx-pip-face idle" data-hx="pipFace">
      <ellipse cx="52" cy="50" rx="24" ry="29" fill="none" stroke="rgba(246,239,226,0.4)" stroke-width="1.4" />
      <g>
        <circle cx="38" cy="38" r="1.7" fill="${TERRA}" /><circle cx="47" cy="35" r="1.7" fill="${TERRA}" />
        <circle cx="57" cy="35" r="1.7" fill="${TERRA}" /><circle cx="66" cy="38" r="1.7" fill="${TERRA}" />
        <circle cx="52" cy="52" r="1.7" fill="${TERRA}" />
        <circle cx="40" cy="64" r="1.7" fill="${TERRA}" /><circle cx="52" cy="70" r="1.7" fill="${TERRA}" />
        <circle cx="64" cy="64" r="1.7" fill="${TERRA}" />
        <path d="M38 38 L47 35 M57 35 L66 38 M47 35 L52 52 L57 35 M40 64 L52 70 L64 64 M40 64 L52 52 L64 64"
          stroke="${TERRA}" stroke-width="0.7" opacity="0.45" />
      </g>
      <g data-hx="eyesOpen">
        <circle cx="43" cy="44" r="3.2" fill="${PERI}" />
        <circle cx="61" cy="44" r="3.2" fill="${PERI}" />
      </g>
      <g data-hx="eyesShut" opacity="0">
        <path d="M39.5 44 h7" stroke="${PERI}" stroke-width="2.2" stroke-linecap="round" />
        <path d="M57.5 44 h7" stroke="${PERI}" stroke-width="2.2" stroke-linecap="round" />
      </g>
      <path d="M47 59 Q52 62 57 59" stroke="rgba(246,239,226,0.5)" stroke-width="1.3" fill="none" />
    </g>
  </svg>`;

export function mountHero(el: HTMLElement | null, lang: Lang, S: HeroStrings): void {
  if (!el) return;
  const timeline = TIMELINES[lang];
  const T = timeline.t;
  const AG = timeline.agents;
  const LOOP = INTRO + timeline.duration + LOOP_GAP;

  // dev: ?hxt=SEC freezes the virtual clock for screenshots
  const freezeParam = new URLSearchParams(location.search).get("hxt");
  const FREEZE = freezeParam == null ? null : parseFloat(freezeParam);

  // the gaze keyframes — same shape the audio generator rendered with,
  // shifted into virtual time. One turn only: B finishes, you look RIGHT
  // while A keeps working on the left.
  const POSE: [number, number][] = [
    [0, 0],
    [INTRO + T.gazeB, 0],
    [INTRO + T.gazeB + 0.9, AG.B.bearingDeg],
    [INTRO + T.eyesOpen, AG.B.bearingDeg],
    [INTRO + T.eyesOpen + 1, 0],
  ];
  function yawDegAt(t: number): number {
    if (t <= POSE[0][0]) return POSE[0][1];
    for (let i = 0; i < POSE.length - 1; i++) {
      const [t0, y0] = POSE[i];
      const [t1, y1] = POSE[i + 1];
      if (t >= t0 && t <= t1) {
        const u = t1 > t0 ? (t - t0) / (t1 - t0) : 1;
        const s = u * u * (3 - 2 * u);
        return y0 + (y1 - y0) * s;
      }
    }
    return POSE[POSE.length - 1][1];
  }

  // earcon moments (match gen-hero-audio.py), in virtual time: B's done-ping,
  // A's little tool ticks
  const PINGS: { agent: AgentKey; t: number }[] = [{ agent: "B", t: INTRO + T.pingB }];
  const TICKS = timeline.ticksA.map((t) => INTRO + t);

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
    </div>

    <div class="hx-layer hx-world" data-hx="world" style="opacity:0">
      <canvas data-hx="canvas"></canvas>
      <div class="hx-cap" data-hx="capA">${timeline.captions.working_A}</div>
      <div class="hx-cap" data-hx="capB">${timeline.captions.summary_B}</div>
    </div>

    <div class="hx-lid top" data-hx="lidT"></div>
    <div class="hx-lid bottom" data-hx="lidB"></div>

    <div class="hx-pip" data-hx="pip">
      ${pipSvg}
      <div class="hx-pip-tag">
        <span class="hx-pip-dot"></span><span>${S.watching}</span>
      </div>
    </div>

    <!-- the letter belongs to the agent being answered — B, the docs agent -->
    <div class="hx-letter" data-hx="letter">
      <div class="hx-letter-head">
        <span class="hx-letter-dot" style="background:${AG.B.color};box-shadow:0 0 8px ${AG.B.color}"></span>
        <span class="hx-letter-name">${AG.B.name}</span>
        <span class="hx-letter-kind">Claude Code</span>
      </div>
      <div class="hx-letter-line"><b>${S.done}</b><span>${timeline.captions.summary_B}</span></div>
      <div class="hx-letter-input" data-hx="input"><span data-hx="typed"></span><span class="hx-caret"></span></div>
    </div>

    <button class="hx-sound" data-hx="sound" aria-label="${S.unmute}" title="${S.unmute}">${soundIcon(true)}</button>
  `;

  const $ = <E extends HTMLElement = HTMLElement>(k: string) =>
    el.querySelector(`[data-hx="${k}"]`) as E;
  const desk = $("desk");
  const world = $("world");
  const pip = $("pip");
  const canvas = $<HTMLCanvasElement>("canvas");
  const g = canvas.getContext("2d")!;
  const capEls = { A: $("capA"), B: $("capB") };
  const letter = $("letter");
  const typed = $("typed");
  const input = $("input");
  const soundBtn = $<HTMLButtonElement>("sound");
  const pipFace = el.querySelector('[data-hx="pipFace"]') as SVGGElement;
  const eyesOpenG = el.querySelector('[data-hx="eyesOpen"]') as SVGGElement;
  const eyesShutG = el.querySelector('[data-hx="eyesShut"]') as SVGGElement;

  // quotes around the captions, per script
  const q = lang === "zh-Hant" ? ["「", "」"] : lang === "ru" ? ["«", "»"] : ["“", "”"];
  capEls.A.textContent = q[0] + timeline.captions.working_A + q[1];
  capEls.B.textContent = q[0] + timeline.captions.summary_B + q[1];

  const audio = new Audio(`/hero-demo.${lang}.m4a`);
  audio.preload = "auto";

  // ---- the virtual clock -------------------------------------------------------
  // Muted (and always during the intro beat) time comes from a monotonic
  // anchor; with sound on, once past INTRO, it re-anchors to the audio.
  let soundOn = false;
  let audioPhase = false; // audio is the clock right now
  let anchor = performance.now();
  let raf = 0;
  let disposed = false;

  const now = () =>
    audioPhase ? INTRO + audio.currentTime : (performance.now() - anchor) / 1000;

  function restartLoop() {
    audioPhase = false;
    anchor = performance.now();
    if (!audio.paused) audio.pause();
    audio.currentTime = 0;
  }

  const paintSound = () => {
    soundBtn.innerHTML = soundIcon(!soundOn);
    soundBtn.ariaLabel = soundBtn.title = soundOn ? S.soundOn : S.unmute;
    soundBtn.classList.toggle("lit", soundOn);
  };
  soundBtn.addEventListener("click", () => {
    soundOn = !soundOn;
    paintSound();
    const t = now();
    if (soundOn) {
      if (t >= INTRO) {
        audio.currentTime = Math.min(t - INTRO, timeline.duration - 0.05);
        void audio.play().then(() => { audioPhase = true; }).catch(() => { soundOn = false; paintSound(); });
      } else {
        // unlock the element inside the gesture; the frame loop starts it at INTRO
        void audio.play().then(() => {
          if (!audioPhase) { audio.pause(); audio.currentTime = 0; }
        }).catch(() => { soundOn = false; paintSound(); });
      }
      if (!soundOn) paintSound();
    } else {
      anchor = performance.now() - t * 1000;
      audioPhase = false;
      audio.pause();
    }
  });

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
    const yaw = rad(yawDegAt(t));

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

      // A never finishes — it works, mutters, ticks. B is done at its ping.
      const done = key === "B" && t >= INTRO + T.pingB - 0.05;
      const lineStart = INTRO + (key === "A" ? T.lineA : T.lineB);
      const lineEnd = INTRO + (key === "A" ? T.lineAEnd : T.lineBEnd);
      const speaking = t >= lineStart - 0.4 && t <= lineEnd + 0.2;
      const heard = key === "B" && t > lineEnd + 0.2;

      // the done-ping ripple (gold, news)
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
      // tool ticks (teal, quick and small — work, not news)
      if (key === "A") {
        for (const tk of TICKS) {
          const age = (t - tk) / 0.45;
          if (age >= 0 && age < 1) {
            const rr = 6 + age * s * 0.1;
            g.beginPath();
            g.arc(px, py, rr, 0, TAU);
            g.strokeStyle = `rgba(95,208,197,${0.45 * (1 - age)})`;
            g.lineWidth = 1.6;
            g.stroke();
          }
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
    if (disposed) return;
    let t = FREEZE ?? now();

    // the intro→main boundary: hand the clock to the audio when sound is on
    if (FREEZE == null && t >= INTRO && !audioPhase && soundOn) {
      audio.currentTime = Math.min(t - INTRO, timeline.duration - 0.05);
      void audio.play().then(() => { audioPhase = true; });
    }

    // loop
    if (FREEZE == null && t >= LOOP) {
      restartLoop();
      t = 0;
    }

    pip.classList.toggle("on", FREEZE == null ? t >= PIP_IN : t >= PIP_IN - 0.5);

    // desktop ↔ world layering
    const lidsClosed = t >= INTRO + T.eyesClose + 0.2 && t < INTRO + T.worldIn + 0.25;
    el!.classList.toggle("hx-lids-closed", lidsClosed);
    const inWorld = t >= INTRO + T.worldIn && t < INTRO + T.eyesOpen + 0.4;
    world.style.opacity = inWorld ? "1" : "0";
    desk.style.opacity = inWorld ? "0" : "1";

    // the PiP mirrors the imaginary user (the lids in the tile say it all —
    // no state label)
    const shut = t >= INTRO + T.eyesClose && t < INTRO + T.eyesOpen;
    eyesOpenG.setAttribute("opacity", shut ? "0" : "1");
    eyesShutG.setAttribute("opacity", shut ? "1" : "0");
    const yd = yawDegAt(t);
    if (Math.abs(yd) > 0.5) {
      pipFace.classList.remove("idle");
      pipFace.style.transform = `translateX(${(-yd * 0.5).toFixed(1)}px) rotate(${(-yd * 0.22).toFixed(1)}deg)`;
    } else {
      pipFace.style.transform = "";
      pipFace.classList.add("idle");
    }

    if (inWorld || FREEZE != null) drawWorld(t);

    // the letter, after the eyes open
    if (t >= INTRO + T.letterIn && t < INTRO + T.send + 1.2) {
      letter.classList.add("on");
      const chars = Math.max(
        0,
        Math.floor(
          ((t - INTRO - T.typeStart) / (T.typeEnd - T.typeStart)) * timeline.reply.length,
        ),
      );
      typed.textContent = timeline.reply.slice(0, Math.min(chars, timeline.reply.length));
      if (t >= INTRO + T.send) input.classList.add("sent");
    } else {
      letter.classList.remove("on");
      input.classList.remove("sent");
      typed.textContent = "";
    }

    if (FREEZE == null) raf = requestAnimationFrame(frame);
  }

  // a language re-render replaces the DOM — stop the old loop and its audio
  const observer = new MutationObserver(() => {
    if (!document.contains(el)) {
      disposed = true;
      cancelAnimationFrame(raf);
      audio.pause();
      observer.disconnect();
    }
  });
  observer.observe(document.body, { childList: true, subtree: true });

  frame();
}
