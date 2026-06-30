import { Chamber } from "./audio/engine";
import { HeadTracker, type Calibration } from "./tracking/headTracking";
import { initRadar } from "./ui/radar";
import "./ui/styles.css";

const $ = <T extends HTMLElement = HTMLElement>(id: string) =>
  document.getElementById(id) as T;
const wait = (ms: number) => new Promise((r) => setTimeout(r, ms));

// Live mode (?live): drive the agents from a real local Claude Code session via the
// bridge, instead of the standalone auto-finishing demo. See docs/cc-integration-plan.md.
const LIVE = new URLSearchParams(location.search).has("live");

const CAL_KEY = "agent-chamber-calibration";
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

const engine = new Chamber();
const tracker = new HeadTracker();
const canvas = $<HTMLCanvasElement>("radar");
initRadar(engine, canvas);

const intro = $("intro");
const enableBtn = $<HTMLButtonElement>("enable");
const startBtn = $<HTMLButtonElement>("start");
const statusEl = $("status");
const recalBtn = $<HTMLButtonElement>("recal");
const calib = $("calib");
const calArrow = $("calArrow");
const calText = $("calText");

type Clips = { left: AudioBuffer; right: AudioBuffer; done: AudioBuffer };
let clips: Clips | null = null;

function setStatus(text: string, kind: "" | "ok" | "err" = "") {
  statusEl.textContent = text;
  statusEl.className = "status" + (kind ? " " + kind : "");
}

let startReady = false;
function revealStart(label: string) {
  if (startReady) return;
  startReady = true;
  startBtn.textContent = label;
  startBtn.hidden = false;
  recalBtn.hidden = loadCal() === null; // only offered once a calibration exists
}

recalBtn.onclick = () => {
  localStorage.removeItem(CAL_KEY);
  recalBtn.hidden = true;
  setStatus("Will recalibrate on start", "ok");
};

// Step 1 — one gesture: spin up audio, request camera, load model + clips.
enableBtn.onclick = async () => {
  enableBtn.disabled = true;
  enableBtn.classList.add("busy");
  try {
    setStatus("Starting audio…");
    await engine.start(LIVE ? "live" : "demo"); // builds the graph; stays silent until Start

    setStatus("Requesting camera…");
    await tracker.startCamera();

    setStatus("Loading head-tracking model…");
    await tracker.loadModel();
    const [left, right, done] = await Promise.all([
      engine.loadClip("audio/cal_left.mp3"),
      engine.loadClip("audio/cal_right.mp3"),
      engine.loadClip("audio/cal_done.mp3"),
    ]);
    clips = { left, right, done };

    setStatus("Look at your screen…");
    tracker.startLoop(() => {
      setStatus("Head tracking ready", "ok");
      revealStart("Start");
    });
    setTimeout(() => revealStart("Start anyway"), 5000);

    enableBtn.hidden = true;
  } catch (err) {
    const e = err as Error;
    setStatus(
      e.name === "NotAllowedError"
        ? "Camera permission denied — enable it and reload."
        : "Couldn't start: " + (e.message || e.name),
      "err",
    );
    enableBtn.disabled = false;
    enableBtn.classList.remove("busy");
  }
};

// Step 2 — calibrate (first time) then begin the experience.
startBtn.onclick = async () => {
  startBtn.disabled = true;
  await engine.resume(); // unmute (still no auto-finishing yet)

  const stored = loadCal();
  if (stored) tracker.apply(stored);
  else await runCalibration();

  tracker.attach(engine); // go live with the calibration
  intro.classList.add("gone");
  calib.hidden = true;
  if (LIVE) {
    const { connectLive } = await import("./live/bridge");
    connectLive(engine); // agents driven by a real Claude Code session
  } else {
    engine.startAuto(); // standalone demo: agents finish on their own
  }
};

/** Voice-guided two-point calibration: look fully left, then fully right. */
async function runCalibration() {
  intro.classList.add("gone");
  calib.hidden = false;

  const prompt = async (
    arrow: string,
    text: string,
    clip: AudioBuffer | undefined,
  ) => {
    calArrow.textContent = arrow;
    calArrow.className = "cal-arrow show";
    calText.textContent = text;
    if (clip) await engine.playClip(clip);
    else await wait(2200);
    await wait(1300); // let them settle into the hold before sampling
  };

  await prompt("←", "Look all the way left… and hold", clips?.left);
  const yawLeft = tracker.yaw,
    pitchL = tracker.pitch;

  await prompt("→", "Now all the way right… and hold", clips?.right);
  const yawRight = tracker.yaw,
    pitchR = tracker.pitch;

  tracker.calibrate(yawLeft, yawRight, (pitchL + pitchR) / 2);
  saveCal(tracker.calibration);

  calArrow.textContent = "✓";
  calText.textContent = "Calibrated";
  if (clips?.done) await engine.playClip(clips.done);
  await wait(400);
  calib.hidden = true;
}
