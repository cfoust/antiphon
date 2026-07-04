// Antiphon marketing site — static sections, rendered from the language table.
// Visual spec: design_handoff_antiphon_site/Antiphon.dc.html (+ README design tokens).
// The listening-room panel (#listen-panel) internals are owned by hero.ts.

import "@fontsource/gfs-didot/400.css";
import "@fontsource/cormorant-garamond/400-italic.css";
import "@fontsource/instrument-sans/400.css";
import "@fontsource/instrument-sans/500.css";
import "@fontsource/instrument-sans/600.css";
import "./site.css";

import { mountHero } from "./hero";
import { VERSION } from "../version";
import { detectLang, saveLang, LANGS, LANG_LABELS, SITE, type Lang } from "./i18n";

const GITHUB_URL = "https://github.com/cfoust/antiphon";
// Fallback: the releases page. resolveDownloadLinks() upgrades every
// a[data-dl] to the latest versioned Antiphon-<v>-macOS.zip once known.
const DOWNLOAD_URL = `${GITHUB_URL}/releases/latest`;

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
const tenetIcons = [
  `<svg width="44" height="44" viewBox="0 0 44 44" aria-hidden="true"><circle cx="22" cy="22" r="20" fill="none" stroke="#2743B8" stroke-width="1.5"/><circle cx="12" cy="26" r="3.5" fill="#C4694A"/><circle cx="32" cy="16" r="3.5" fill="#2743B8"/><circle cx="22" cy="34" r="2.5" fill="#2A231B"/></svg>`,
  `<svg width="44" height="44" viewBox="0 0 44 44" aria-hidden="true"><circle cx="22" cy="22" r="6" fill="#C4694A"/><circle cx="22" cy="22" r="12" fill="none" stroke="#C4694A" stroke-width="1.2" opacity="0.55"/><circle cx="22" cy="22" r="18" fill="none" stroke="#C4694A" stroke-width="1" opacity="0.3"/></svg>`,
  `<svg width="44" height="44" viewBox="0 0 44 44" aria-hidden="true"><path d="M8 18 Q22 4 36 18" fill="none" stroke="#2743B8" stroke-width="1.6"/><path d="M36 26 Q22 40 8 26" fill="none" stroke="#C4694A" stroke-width="1.6"/></svg>`,
];

function page(lang: Lang): string {
  const S = SITE[lang];

  const langSwitch = `
    <span class="anph-lang" role="group" aria-label="Language">
      ${LANGS.map(
        (l) =>
          `<button class="anph-lang-btn${l === lang ? " on" : ""}" data-lang="${l}">${LANG_LABELS[l]}</button>`,
      ).join("")}
    </span>`;

  const nav = `
<nav class="anph-nav">
  <div class="anph-nav-inner">
    <a href="#top" class="anph-nav-logo">
      ${navEyeSvg}
      <span class="anph-nav-wordmark">Antiphon</span>
    </a>
    <div class="anph-nav-links">
      <span class="anph-nav-textlinks anph-nav-links">
        <a href="#listen">${S.nav.sounds}</a>
        <a href="#feel">${S.nav.feels}</a>
        <a href="#engineering">${S.nav.engineering}</a>
        <a href="${GITHUB_URL}">GitHub</a>
      </span>
      ${langSwitch}
      <a href="#get" class="anph-nav-cta">${S.nav.download}</a>
    </div>
  </div>
</nav>`;

  // The demo IS the hero: headline-first with the panel beneath on desktop
  // (the tracking eye perched on its edge), the panel as the full first
  // viewport with the copy overlaid on phones. hero.css owns the flip.
  const hero = `
<header id="top" class="anph-hero anph-hero--stage">
  <div class="anph-hero-copy">
    <h1>${S.hero.h1}</h1>
    <p class="anph-hero-sub">${S.hero.sub}</p>
    <div class="anph-hero-ctas">
      <a href="${DOWNLOAD_URL}" data-dl class="anph-btn anph-btn--primary">${S.hero.download}</a>
      <a href="/demo.html" class="anph-btn anph-btn--secondary">${S.hero.browser}</a>
    </div>
    <div class="anph-fineprint">${S.hero.fineprint}</div>
  </div>
  <div class="anph-stage">
    <div id="listen-panel" class="listen-panel"></div>
  </div>
</header>`;

  const listen = `
<section id="listen" class="anph-listen">
  <div class="anph-listen-inner">
    <div class="anph-hero-eye-wrap">
      ${heroEyeSvg}
      <div class="anph-halo"></div>
      <div class="anph-halo anph-halo--outer"></div>
    </div>
    <div class="anph-eyebrow">${S.listen.eyebrow}</div>
    <h2 class="anph-h2" style="margin-bottom:18px">${S.listen.h2}</h2>
    <p class="anph-listen-intro">${S.listen.intro}</p>
    <p class="anph-listen-note">${S.listen.note}</p>
    <div class="anph-listen-demo-cta">
      <a href="/demo.html" class="anph-btn anph-btn--primary">${S.listen.cta}</a>
    </div>
  </div>
</section>`;

  const feel = `
<section id="feel" class="anph-feel">
  <div class="anph-feel-inner">
    <div class="anph-section-head">
      <div class="anph-eyebrow">${S.feel.eyebrow}</div>
      <h2 class="anph-h2">${S.feel.h2}</h2>
    </div>
    <div class="anph-exchange">
      ${S.feel.bubbles
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
      ${S.feel.tenets
        .map(
          (t, i) => `
      <div class="anph-tenet">
        ${tenetIcons[i]}
        <div class="anph-tenet-title">${t.title}</div>
        <div class="anph-tenet-body">${t.body}</div>
      </div>`,
        )
        .join("")}
    </div>
  </div>
</section>`;

  const agents: { name: string; badge: string; muted?: boolean; terracotta?: boolean }[] = [
    { name: "Claude Code", badge: S.choir.full },
    { name: "Codex CLI", badge: S.choir.full },
    { name: "OpenCode", badge: S.choir.full },
    { name: "Pi", badge: S.choir.fullTalkback },
    { name: "Aider", badge: S.choir.presence },
    { name: S.choir.yourAgent, badge: S.choir.openProtocol, muted: true, terracotta: true },
  ];

  const choir = `
<section id="choir" class="anph-choir">
  <div class="anph-choir-inner">
    <div class="anph-eyebrow">${S.choir.eyebrow}</div>
    <h2 class="anph-h2" style="margin-bottom:18px">${S.choir.h2}</h2>
    <p class="anph-choir-intro">${S.choir.intro}</p>
    <div class="anph-agent-list">
      ${agents
        .map(
          (a) => `
      <div class="anph-agent-row">
        <span class="anph-agent-name${a.muted ? " anph-agent-name--muted" : ""}">${a.name}</span>
        <span class="anph-badge${a.terracotta ? " anph-badge--terracotta" : ""}">${a.badge}</span>
      </div>`,
        )
        .join("")}
    </div>
    <div class="anph-choir-link"><a href="${GITHUB_URL}">${S.choir.link}</a></div>
  </div>
</section>`;

  const engineering = `
<section id="engineering" class="anph-engineering">
  <div class="anph-engineering-inner">
    <div class="anph-section-head">
      <div class="anph-eyebrow">${S.eng.eyebrow}</div>
      <h2 class="anph-h2">${S.eng.h2}</h2>
    </div>
    <div class="anph-eng-grid">
      ${S.eng.cards
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
    <h2>${S.get.h2}</h2>
    <p class="anph-get-sub">${S.get.sub}</p>
    <div class="anph-get-ctas">
      <a href="${DOWNLOAD_URL}" data-dl class="anph-btn anph-btn--primary">${S.get.download}</a>
      <a href="/demo.html" class="anph-btn anph-btn--secondary">${S.get.demo}</a>
    </div>
    <div class="anph-fineprint">${S.get.fineprint}</div>
  </div>
</section>`;

  const footer = `
<footer class="anph-footer">
  <div class="anph-footer-inner">
    <div class="anph-footer-brand">
      ${footerEyeSvg}
      <span>antiphon.dev</span>
    </div>
    <div class="anph-footer-greek">${S.footer.greek}</div>
    <div class="anph-footer-links">
      <a href="${GITHUB_URL}">GitHub</a>
      <a href="/docs/${lang === "en" ? "" : lang + "/"}">${S.footer.docs}</a>
      <a href="/docs/${lang === "en" ? "" : lang + "/"}privacy/">${S.footer.privacy}</a>
      <span class="anph-footer-version">${VERSION === "0.0.0-dev" ? "" : `v${VERSION}`}</span>
    </div>
  </div>
</footer>`;

  return nav + hero + listen + feel + choir + engineering + get + footer;
}

let dlResolved: string | null = null;
async function resolveDownloadLinks(): Promise<void> {
  try {
    if (!dlResolved) {
      const r = await fetch("https://api.github.com/repos/cfoust/antiphon/releases/latest");
      if (!r.ok) return;
      const j = (await r.json()) as { assets?: { name: string; browser_download_url: string }[] };
      dlResolved =
        j.assets?.find((a) => /^Antiphon-.*-macOS\.zip$/.test(a.name))?.browser_download_url ?? null;
    }
    if (dlResolved) {
      document.querySelectorAll<HTMLAnchorElement>("a[data-dl]").forEach((a) => {
        a.href = dlResolved!;
      });
    }
  } catch {
    /* the releases-page fallback href stands */
  }
}

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

function render(lang: Lang): void {
  if (!root) return;
  document.documentElement.lang = lang;
  document.title = SITE[lang].title;
  root.innerHTML = page(lang);
  mountHero(document.getElementById("listen-panel"), lang, SITE[lang].hx);
  initPupilTracking();
  void resolveDownloadLinks();
  root.querySelectorAll<HTMLButtonElement>(".anph-lang-btn").forEach((b) => {
    b.addEventListener("click", () => {
      const l = b.dataset.lang as Lang;
      if (l === lang) return;
      saveLang(l);
      render(l);
    });
  });
}

render(detectLang());
