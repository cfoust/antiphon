import "@fontsource/gfs-didot"; // the Antiphon serif (title + tagline)
import "@fontsource/instrument-sans"; // onboarding body
import "@fontsource/instrument-sans/500.css";
import "@fontsource/instrument-sans/600.css";
import { DEMO_AGENT_COUNT } from "./agents";
import { Antiphon } from "./audio/engine";
import { HeadTracker, type Calibration } from "./tracking/headTracking";
import { initAgentList } from "./ui/agentList";
import { initRadar } from "./ui/radar";
import "./ui/styles.css";
import { D, lang, setDemoLang, saveLang, LANGS, LANG_LABELS } from "./demoI18n";

// The Antiphon web demo: the native app's experience in a browser tab.
// Onboarding mirrors Onboarding.swift's three beats — a full-bleed dark
// welcome (the concentric eye watching the cursor), a voice-guided hold-still
// calibration, then Fit with the guide voice looping from straight ahead —
// and then the room runs a SCRIPTED scenario (src/demo/scenario.ts): agents
// audibly working, completing tasks, and speaking generated summaries when
// you face them. No talk-back here; ?live drives it from a real session.

const $ = <T extends HTMLElement = HTMLElement>(id: string) =>
  document.getElementById(id) as T;
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Live mode (?live): drive the agents from a real local Claude Code session via the
// bridge, instead of the standalone scripted demo. See docs/cc-integration-plan.md.
const LIVE = new URLSearchParams(location.search).has("live");

const CAL_KEY = "agent-antiphon-calibration";
const FIT_KEY = "antiphon-fit";
const ONBOARD_KEY = "antiphon-onboarded"; // the Fit beat was completed once
function loadCal(): Calibration | null {
  try {
    return JSON.parse(localStorage.getItem(CAL_KEY) || "null");
  } catch {
    return null;
  }
}
function saveCal(c: Calibration) {
  localStorage.setItem(CAL_KEY, JSON.stringify(c));
}

const engine = new Antiphon();
if (!LIVE) engine.activeCount = DEMO_AGENT_COUNT; // the scripted roster
{
  const f = parseFloat(localStorage.getItem(FIT_KEY) || "");
  if (Number.isFinite(f)) engine.setFit(f);
}
const tracker = new HeadTracker();
const canvas = $<HTMLCanvasElement>("radar");
initRadar(engine, canvas);
const agentList = $("agentList");
initAgentList(engine, agentList);

// Head tracking is best-effort: on phones (or with the camera denied) the room
// still works — radar, drag, list and audio — just without head-driven pose.
let tracking = false;

const onboard = $("onboard");
const welcome = $("welcome");
const enableBtn = $<HTMLButtonElement>("enable");
const startBtn = $<HTMLButtonElement>("start");
const statusEl = $("status");
const calib = $("calib");
const calArrow = $("calArrow");
const calText = $("calText");
const calHold = $("calHold");
const calHoldLabel = $("calHoldLabel");
const fitStep = $("fitStep");
const obFit = $<HTMLInputElement>("obFit");
const obFitVal = $("obFitVal");
const fitDoneBtn = $<HTMLButtonElement>("fitDone");
const eyesStep = $("eyesStep");
const eyesIcon = $("eyesIcon");
const eyesText = $("eyesText");
const eyesSkip = $<HTMLButtonElement>("eyesSkip");

// ---- language: applied to every static string; switchable on the welcome ---
function applyLang() {
  document.documentElement.lang = lang;
  document.title = D.title;
  $("obTag").textContent = D.tag;
  $("obBody").textContent = D.body;
  $("obNote").textContent = D.headphonesNote;
  enableBtn.textContent = D.enable;
  $("camNote").textContent = D.camNote;
  $("obFoot").textContent = D.foot;
  calText.textContent = D.calLeft;
  $("fitTitle").textContent = D.fitTitle;
  $("fitSub").textContent = D.fitSub;
  fitDoneBtn.textContent = D.continueLabel;
  eyesText.textContent = D.eyesPrompt;
  eyesSkip.textContent = D.skip;
  const say = document.getElementById("sayText") as HTMLInputElement | null;
  if (say) say.placeholder = D.sayPlaceholder;
  document.querySelectorAll<HTMLButtonElement>(".ob-lang-btn").forEach((b) => {
    b.classList.toggle("on", b.dataset.lang === lang);
  });
}
{
  const row = $("obLangs");
  for (const l of LANGS) {
    const b = document.createElement("button");
    b.type = "button";
    b.className = "ob-lang-btn";
    b.dataset.lang = l;
    b.textContent = LANG_LABELS[l];
    b.onclick = () => {
      setDemoLang(l);
      saveLang(l);
      applyLang();
    };
    row.appendChild(b);
  }
}

// ---- the eye watches the cursor (hero behavior, mirrors WelcomeView) -------
const eye = $("eye");
const eyePupil = $("eyePupil");
onboard.addEventListener("pointermove", (e) => {
  if (welcome.hidden) return;
  const r = eye.getBoundingClientRect();
  const cx = r.left + r.width / 2,
    cy = r.top + r.height / 2;
  const dx = e.clientX - cx,
    dy = e.clientY - cy;
  const dist = Math.max(Math.hypot(dx, dy), 1);
  const mag = Math.min(dist / 300, 1) * r.width * 0.1; // ±13 px on the 130 px eye
  eyePupil.style.transform = `translate(${(dx / dist) * mag}px, ${(dy / dist) * mag}px)`;
});
onboard.addEventListener("pointerleave", () => {
  eyePupil.style.transform = "";
});

applyLang();

// ---- HRTF "fit" (the onboarding beat's slider) -----------------------------
function showFit(v: number) {
  const s = v.toFixed(2);
  obFit.value = String(v);
  obFitVal.textContent = s;
}
function applyFit(v: number) {
  engine.setFit(v);
  showFit(v);
  localStorage.setItem(FIT_KEY, String(v));
}
showFit(engine.fit);
obFit.oninput = () => applyFit(parseFloat(obFit.value));

type Clips = {
  left: AudioBuffer | null;
  right: AudioBuffer | null;
  done: AudioBuffer | null;
  fit: AudioBuffer | null;
  eyes: AudioBuffer | null;
};
let clips: Clips | null = null;

function setStatus(text: string, kind: "" | "ok" | "err" = "") {
  statusEl.textContent = text;
  statusEl.className = "ob-status" + (kind ? " " + kind : "");
}

let startReady = false;
function revealStart(label: string) {
  if (startReady) return;
  startReady = true;
  startBtn.textContent = label;
  startBtn.hidden = false;
}

// Beat 1 — one gesture: spin up audio, request camera, load model + clips.
enableBtn.onclick = async () => {
  enableBtn.disabled = true;
  $("obLangs").style.display = "none"; // cues load now — the choice is made
  enableBtn.classList.add("busy");
  try {
    setStatus(D.startingAudio);
    await engine.start(LIVE ? "live" : "demo"); // builds the graph; stays silent until Start
  } catch (err) {
    const e = err as Error;
    setStatus(D.cantStartAudio + (e.message || e.name), "err");
    enableBtn.disabled = false;
    enableBtn.classList.remove("busy");
    return;
  }
  // the spoken onboarding cues (best effort — the flow works silent too)
  const clip = (url: string) => engine.loadClip(url).catch(() => null);
  const clipsP = Promise.all([
    clip(`audio/cal_left.${lang}.mp3`),
    clip(`audio/cal_right.${lang}.mp3`),
    clip(`audio/cal_done.${lang}.mp3`),
    clip(`audio/fit.${lang}.mp3`),
    clip(`audio/close_eyes.${lang}.mp3`), // best effort — silent until voices are regenerated
  ]).then(([left, right, done, fit, eyes]) => {
    clips = { left, right, done, fit, eyes };
  });
  try {
    setStatus(D.requestingCamera);
    await tracker.startCamera();

    setStatus(D.loadingModel);
    await tracker.loadModel();
    await clipsP;
    tracking = true;

    setStatus(D.lookingFace);
    tracker.startLoop(() => {
      setStatus(loadCal() ? D.calRestored : D.trackingReady, "ok");
      revealStart(loadCal() ? D.start : D.continueLabel);
    });
    setTimeout(() => revealStart(D.startAnyway), 5000);
  } catch (err) {
    // No camera (denied, or a phone without tracking) — the room still works:
    // radar, dragging and the agent list, just without head-driven pose.
    const e = err as Error;
    await clipsP;
    setStatus(e.name === "NotAllowedError" ? D.cameraDenied : D.noTracking);
    revealStart(D.startWithout);
  }
  enableBtn.hidden = true;
};

// Beat 2 + 3 — calibrate and fit (first time), then begin the experience.
startBtn.onclick = async () => {
  startBtn.disabled = true;
  await engine.resume(); // unmute (the room stays silent until the scenario starts)

  welcome.hidden = true;
  if (tracking) {
    const stored = loadCal();
    if (stored) tracker.apply(stored);
    else await runCalibration();
    tracker.attach(engine); // go live with the calibration
  }
  if (!localStorage.getItem(ONBOARD_KEY)) {
    await runFit();
    if (tracking) await runCloseEyes(); // the defining gesture — needs the eye tracker
    localStorage.setItem(ONBOARD_KEY, "1");
  }

  onboard.classList.add("gone");
  agentList.hidden = false; // reveal the room list once the experience is live
  if (LIVE) {
    const { connectLive } = await import("./live/bridge");
    connectLive(engine); // agents driven by a real Claude Code session
  } else {
    // the scripted scenario: agents work audibly and complete tasks over time
    const { startScenario } = await import("./demo/scenario");
    await startScenario(engine, lang);
  }
};

// ---- beat 2: voice-guided two-point calibration with hold-still locks ------
// (mirrors CalibrationStepView: turn >10° away, hold ~1 s within ~2.5°, the
// teal capsule fills). A per-side timeout falls back to sampling the current
// pose so a jittery tracker can never trap anyone here.
const HOLD_MS = 1000;
const TURN_MIN_DEG = 10;
const STILL_TOL_DEG = 2.5;
const SIDE_TIMEOUT_MS = 14000;

function setHold(frac: number) {
  calHold.style.width = (frac * 100).toFixed(1) + "%";
  calHoldLabel.textContent = frac > 0 ? "Hold still…" : " ";
}

/** Resolve with the locked pose once the head has turned away from `yaw0` and
 *  held still; `oppositeOf` forces the other side of the first lock. */
function holdLock(
  yaw0: number,
  oppositeOf: number | null,
): Promise<{ yaw: number; pitch: number }> {
  return new Promise((res) => {
    let anchor = NaN;
    let holdStart = 0;
    const begun = performance.now();
    const step = () => {
      const now = performance.now();
      const yaw = tracker.yaw;
      const dev = yaw - yaw0;
      let turned = Math.abs(dev) > TURN_MIN_DEG;
      if (oppositeOf !== null)
        turned = turned && (dev >= 0) !== (oppositeOf - yaw0 >= 0);
      const finish = () => {
        setHold(0);
        res({ yaw, pitch: tracker.pitch });
      };
      if (now - begun > SIDE_TIMEOUT_MS) return finish(); // fallback: sample as-is
      if (!turned) {
        anchor = NaN;
        setHold(0);
      } else if (Number.isNaN(anchor) || Math.abs(yaw - anchor) > STILL_TOL_DEG) {
        anchor = yaw;
        holdStart = now;
        setHold(0);
      } else {
        const frac = Math.min(1, (now - holdStart) / HOLD_MS);
        setHold(frac);
        if (frac >= 1) return finish();
      }
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
}

async function runCalibration() {
  calib.hidden = false;

  const cue = (arrow: string, text: string, clip: AudioBuffer | null) => {
    calArrow.textContent = arrow;
    calArrow.className = "cal-arrow show";
    calText.textContent = text;
    if (clip) void engine.playClip(clip); // speak over the hold, not before it
  };

  const yaw0 = tracker.yaw; // where the head is when the step begins
  cue("←", D.calLeft, clips?.left ?? null);
  const L = await holdLock(yaw0, null);

  cue("→", D.calRight, clips?.right ?? null);
  const R = await holdLock(yaw0, L.yaw);

  tracker.calibrate(L.yaw, R.yaw, (L.pitch + R.pitch) / 2);
  saveCal(tracker.calibration);

  calArrow.textContent = "✓";
  calText.textContent = D.calDone;
  setHold(0);
  if (clips?.done) await engine.playClip(clips.done);
  await wait(400);
  calib.hidden = true;
}

// ---- beat 3: fit, with the guide voice looping from straight ahead ---------
// The voice plays THROUGH the binaural engine at bearing 0 — the fit is right
// when it sits out in front, so ahead is the reference (mirrors FitStepView).
async function runFit() {
  fitStep.hidden = false;
  showFit(engine.fit);
  // the guide voice loops from straight ahead the whole step — the fit is right
  // when it sits out in front, so ahead IS the reference (mirrors FitStepView)
  if (clips?.fit) engine.startFitVoice(clips.fit);
  await new Promise<void>((res) => {
    fitDoneBtn.onclick = () => res();
  });
  engine.stopFitVoice();
  fitStep.hidden = true;
}

// ---- beat 4: close your eyes -----------------------------------------------
// The one gesture the other beats never teach: closing your eyes IS how you
// listen — it fades the room in. Ask once, ring a confirmation chime the instant
// the tracker sees the eyes shut, then hand off into the room (still eyes-closed,
// so the scene comes up on cue). A Skip guards against a tracker that never fires.
async function runCloseEyes() {
  eyesStep.hidden = false;
  eyesIcon.textContent = "◡ ◡";
  eyesText.textContent = D.eyesPrompt;
  if (clips?.eyes) void engine.playClip(clips.eyes); // spoken cue, if bundled
  await new Promise<void>((res) => {
    let settled = false;
    eyesSkip.onclick = () => {
      if (settled) return;
      settled = true;
      res();
    };
    const step = () => {
      if (settled) return;
      if (tracker.eyesClosed) {
        settled = true; // stop polling; hold the confirm beat, then resolve
        engine.chime();
        eyesIcon.textContent = "✓";
        eyesText.textContent = D.eyesDone;
        setTimeout(res, 1400);
        return;
      }
      requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  });
  eyesSkip.onclick = null;
  eyesStep.hidden = true;
}
