// Antiphon marketing site — static sections.
// Visual spec: design_handoff_antiphon_site/Antiphon.dc.html (+ README design tokens).
// The listening-room panel (#listen-panel) internals are owned by hero.ts.

import "@fontsource/gfs-didot/400.css";
import "@fontsource/cormorant-garamond/400-italic.css";
import "@fontsource/instrument-sans/400.css";
import "@fontsource/instrument-sans/500.css";
import "@fontsource/instrument-sans/600.css";
import "./site.css";

import { mountHero } from "./hero";

const GITHUB_URL = "https://github.com/cfoust/antiphon";

// Concentric-circle mati eye mark, at several sizes.
const navEyeSvg = `<svg width="26" height="26" viewBox="0 0 26 26" aria-hidden="true"><circle cx="13" cy="13" r="12" fill="#2743B8"/><circle cx="13" cy="13" r="7.5" fill="#FBF7F0"/><circle cx="13" cy="13" r="3.4" fill="#2A231B"/></svg>`;

const heroEyeSvg = `<svg id="anph-hero-eye" width="220" height="220" viewBox="0 0 220 220" aria-hidden="true">
  <circle cx="110" cy="110" r="108" fill="#FBF7F0" stroke="#2743B8" stroke-width="2.5"/>
  <circle cx="110" cy="110" r="88" fill="#2743B8"/>
  <circle cx="110" cy="110" r="60" fill="#FBF7F0"/>
  <g class="anph-hero-pupil" id="anph-hero-pupil">
    <circle cx="110" cy="110" r="30" fill="#2A231B"/>
    <circle cx="100" cy="100" r="7" fill="#FBF7F0" opacity="0.9"/>
  </g>
</svg>`;

const getEyeSvg = `<svg class="anph-get-eye" width="56" height="56" viewBox="0 0 56 56" aria-hidden="true"><circle cx="28" cy="28" r="26" fill="#2743B8"/><circle cx="28" cy="28" r="16" fill="#FBF7F0"/><circle cx="28" cy="28" r="7" fill="#2A231B"/></svg>`;

const footerEyeSvg = `<svg width="18" height="18" viewBox="0 0 18 18" aria-hidden="true"><circle cx="9" cy="9" r="8" fill="none" stroke="#2743B8" stroke-width="1.4"/><circle cx="9" cy="9" r="2.8" fill="#2743B8"/></svg>`;

// Line-art tenet icons.
const tenetIconSpace = `<svg width="44" height="44" viewBox="0 0 44 44" aria-hidden="true"><circle cx="22" cy="22" r="20" fill="none" stroke="#2743B8" stroke-width="1.5"/><circle cx="12" cy="26" r="3.5" fill="#C4694A"/><circle cx="32" cy="16" r="3.5" fill="#2743B8"/><circle cx="22" cy="34" r="2.5" fill="#2A231B"/></svg>`;
const tenetIconGentle = `<svg width="44" height="44" viewBox="0 0 44 44" aria-hidden="true"><circle cx="22" cy="22" r="6" fill="#C4694A"/><circle cx="22" cy="22" r="12" fill="none" stroke="#C4694A" stroke-width="1.2" opacity="0.55"/><circle cx="22" cy="22" r="18" fill="none" stroke="#C4694A" stroke-width="1" opacity="0.3"/></svg>`;
const tenetIconTalk = `<svg width="44" height="44" viewBox="0 0 44 44" aria-hidden="true"><path d="M8 18 Q22 4 36 18" fill="none" stroke="#2743B8" stroke-width="1.6"/><path d="M36 26 Q22 40 8 26" fill="none" stroke="#C4694A" stroke-width="1.6"/></svg>`;

const nav = `
<nav class="anph-nav">
  <div class="anph-nav-inner">
    <a href="#top" class="anph-nav-logo">
      ${navEyeSvg}
      <span class="anph-nav-wordmark">Antiphon</span>
    </a>
    <div class="anph-nav-links">
      <span class="anph-nav-textlinks anph-nav-links">
        <a href="#listen">How it sounds</a>
        <a href="#feel">How it feels</a>
        <a href="#engineering">Engineering</a>
        <a href="${GITHUB_URL}">GitHub</a>
      </span>
      <a href="#get" class="anph-nav-cta">Download for macOS</a>
    </div>
  </div>
</nav>`;

const hero = `
<header id="top" class="anph-hero">
  <div class="anph-hero-eye-wrap">
    ${heroEyeSvg}
    <div class="anph-halo"></div>
    <div class="anph-halo anph-halo--outer"></div>
  </div>
  <h1>Your agents, speaking.<br>You, listening.</h1>
  <p class="anph-hero-sub">Antiphon gives every coding agent a voice, placed in the room around you. Put on headphones and overhear the work.</p>
  <div class="anph-hero-ctas">
    <a href="#get" class="anph-btn anph-btn--primary">Download for macOS</a>
    <a href="/demo.html" class="anph-btn anph-btn--secondary">Try it in the browser</a>
  </div>
  <div class="anph-fineprint">Free &amp; open source · Headphones recommended</div>
</header>`;

const listen = `
<section id="listen" class="anph-listen">
  <div class="anph-listen-inner">
    <div class="anph-eyebrow">How it sounds</div>
    <h2 class="anph-h2" style="margin-bottom:18px">Close your eyes.</h2>
    <p class="anph-listen-intro">When you do, the terminals disappear and another room appears — voices placed in real space, each exactly where its work is. This is the whole pitch, in fifteen seconds.</p>
    <div id="listen-panel" class="listen-panel"></div>
    <p class="anph-listen-note">In the app, voices are real speech — synthesized, spatialized, and yours to answer. Here, a sketch in tone and caption.</p>
    <div class="anph-listen-demo-cta">
      <a href="/demo.html" class="anph-btn anph-btn--primary">Try the web demo</a>
    </div>
  </div>
</section>`;

interface Bubble {
  label: string;
  text: string;
  you?: boolean;
}

const bubbles: Bubble[] = [
  { label: "agent · to your left", text: "“Reworking the auth token flow. Tests next.”" },
  { label: "you", text: "“Keep the refresh logic. Just tighten expiry.”", you: true },
  { label: "agent · behind, slightly right", text: "“Tests are failing — digging in.”" },
];

interface Tenet {
  icon: string;
  title: string;
  body: string;
}

const tenets: Tenet[] = [
  {
    icon: tenetIconSpace,
    title: "Placed in space",
    body: "Each agent has a position — left, right, near, far. Turn your head and the voices stay put in the room.",
  },
  {
    icon: tenetIconGentle,
    title: "Gentle by design",
    body: "A waiting agent builds a soft harmonic cue in one ear rather than interrupting. Nothing pings. Nothing flashes.",
  },
  {
    icon: tenetIconTalk,
    title: "Talk back",
    body: "Answer in a keystroke — or just speak, with voice input like Wispr Flow. Call and response, across the room.",
  },
];

const feel = `
<section id="feel" class="anph-feel">
  <div class="anph-feel-inner">
    <div class="anph-section-head">
      <div class="anph-eyebrow">How it feels</div>
      <h2 class="anph-h2">Overhear the workshop.</h2>
    </div>
    <div class="anph-exchange">
      ${bubbles
        .map(
          (b) => `
      <div class="anph-bubble-row${b.you ? " anph-bubble-row--you" : ""}">
        <div class="anph-bubble${b.you ? " anph-bubble--you" : ""}">
          <span class="anph-bubble-label">${b.label}</span>${b.text}
        </div>
      </div>`,
        )
        .join("")}
    </div>
    <div class="anph-tenets">
      ${tenets
        .map(
          (t) => `
      <div class="anph-tenet">
        ${t.icon}
        <div class="anph-tenet-title">${t.title}</div>
        <div class="anph-tenet-body">${t.body}</div>
      </div>`,
        )
        .join("")}
    </div>
  </div>
</section>`;

const choir = `
<section id="choir" class="anph-choir">
  <div class="anph-choir-inner">
    <div class="anph-eyebrow">Voices in the choir</div>
    <h2 class="anph-h2" style="margin-bottom:18px">Sings with your agents.</h2>
    <p class="anph-choir-intro">Antiphon listens to agent sessions through a small plugin and a local daemon. Open source, open protocol.</p>
    <div class="anph-agent-list">
      <div class="anph-agent-row">
        <span class="anph-agent-name">Claude Code</span>
        <span class="anph-badge">Supported today</span>
      </div>
      <div class="anph-agent-row">
        <span class="anph-agent-name anph-agent-name--muted">Your agent here</span>
        <span class="anph-badge anph-badge--terracotta">Open protocol · PRs welcome</span>
      </div>
    </div>
    <div class="anph-choir-link"><a href="${GITHUB_URL}">Write an adapter on GitHub →</a></div>
  </div>
</section>`;

interface EngCard {
  index: string;
  title: string;
  body: string;
}

const engCards: EngCard[] = [
  {
    index: "01 · spatial engine",
    title: "Research-grade binaural rendering",
    body: "A real spatial-audio engine written from scratch in Rust: HRTF rendering, early reflections, room reverb. Voices have position, distance, and presence — over ordinary headphones.",
  },
  {
    index: "02 · head tracking",
    title: "The room holds still",
    body: "Your webcam tracks your head. Turn to look at a voice and it stays exactly where it was — anchored to the room, not to your ears.",
  },
  {
    index: "03 · one core",
    title: "Native and web, byte-identical",
    body: "The macOS app and the browser demo run the same DSP core, verified to produce byte-identical output. What you hear in the demo is the product.",
  },
  {
    index: "04 · attention, composed",
    title: "Voices, not notifications",
    body: "Waiting agents build gentle harmonic cues instead of firing alerts. The soundscape is mixed like music — so ten agents feel like a workshop, not a slot machine.",
  },
];

const engineering = `
<section id="engineering" class="anph-engineering">
  <div class="anph-engineering-inner">
    <div class="anph-section-head">
      <div class="anph-eyebrow">Engineering</div>
      <h2 class="anph-h2">Built like an instrument.</h2>
    </div>
    <div class="anph-eng-grid">
      ${engCards
        .map(
          (c) => `
      <div class="anph-eng-card">
        <div class="anph-eng-index">${c.index}</div>
        <div class="anph-eng-title">${c.title}</div>
        <div class="anph-eng-body">${c.body}</div>
      </div>`,
        )
        .join("")}
    </div>
  </div>
</section>`;

const get = `
<section id="get" class="anph-get">
  <div class="anph-get-inner">
    ${getEyeSvg}
    <h2>Let something keep watch.</h2>
    <p class="anph-get-sub">Antiphon lives in your menu bar — a small eye, always listening on your behalf. Free and open source.</p>
    <div class="anph-get-ctas">
      <a href="#get" class="anph-btn anph-btn--primary">Download for macOS</a>
      <a href="/demo.html" class="anph-btn anph-btn--secondary">Open the web demo</a>
    </div>
    <div class="anph-fineprint">macOS 14+ · Apple silicon &amp; Intel · MIT license</div>
  </div>
</section>`;

const footer = `
<footer class="anph-footer">
  <div class="anph-footer-inner">
    <div class="anph-footer-brand">
      ${footerEyeSvg}
      <span>antiphon.dev</span>
    </div>
    <div class="anph-footer-greek">ἀντίφωνον — voices, answering across a space</div>
    <div class="anph-footer-links">
      <a href="${GITHUB_URL}">GitHub</a>
      <a href="#">Docs</a>
    </div>
  </div>
</footer>`;

function initPupilTracking(): void {
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
  const eye = document.getElementById("anph-hero-eye");
  const pupil = document.getElementById("anph-hero-pupil");
  if (!eye || !pupil) return;

  const onMove = (e: MouseEvent) => {
    if (reduceMotion.matches) return;
    const r = eye.getBoundingClientRect();
    // Skip when the hero is off-screen.
    if (r.bottom < 0 || r.top > window.innerHeight) return;
    const cx = r.left + r.width / 2;
    const cy = r.top + r.height / 2;
    const dx = e.clientX - cx;
    const dy = e.clientY - cy;
    const dist = Math.hypot(dx, dy) || 1;
    // Deflection proportional to distance, full 22px beyond ~300px.
    const k = (Math.min(1, dist / 300) * 22) / dist;
    pupil.style.transform = `translate(${dx * k}px, ${dy * k}px)`;
  };
  window.addEventListener("mousemove", onMove);
}

const root = document.getElementById("site");
if (root) {
  root.innerHTML = nav + hero + listen + feel + choir + engineering + get + footer;
  mountHero(document.getElementById("listen-panel"));
  initPupilTracking();
}
