// Chamber renderer test harness. Place sources in space, pick a sci-fi sound + volume,
// move the listener, switch rooms/reflections — all driving the wasm binaural engine.
// A dev 3D head-view (──flag CHAMBER_DEV=1, `just harness-dev`) shows where we think the
// listener's head is, in 3D, alongside the sources.

import { WasmEngine, ENGINE_URLS, type Vec3 } from "./audio/wasmEngine";
import { SFX } from "./audio/sfx";
import { HeadTracker } from "./tracking/headTracking";

const DEFAULT_SFX = SFX.findIndex((s) => s.name.startsWith("drone")); // an audible loop

// Enabled by `just harness-dev` (VITE_DEV3D=1). Vite exposes VITE_-prefixed env on import.meta.
const DEV3D = (import.meta as { env?: Record<string, string> }).env?.VITE_DEV3D === "1";

const ROOMS = ["dry", "room", "hall", "cathedral", "room (BRIR)", "hall (BRIR)"];
const COLORS = ["#7aa2ff", "#5fd0c5", "#ffce6b", "#c08bff", "#ff9d7a", "#9aa6b8", "#6be4a0", "#e46b9a"];

interface Src { id: string; pos: Vec3; gain: number; sfx: number; loop: boolean; color: string; name: string; }

const $ = (id: string) => document.getElementById(id)!;
const map = $("map") as HTMLCanvasElement;
const mapCtx = map.getContext("2d")!;
const dev = $("dev3d") as HTMLCanvasElement;
const devCtx = dev.getContext("2d")!;

let engine: WasmEngine | null = null;
let ctx: AudioContext | null = null;
const sources: Src[] = [];
let selected = -1;
let nextId = 1;
let orientDeg = 0;
let listenerY = 0;
let tracker: HeadTracker | null = null;
let tracking = false;
const SCALE = 36; // px per metre on the top-down map

// ---- audio setup ----------------------------------------------------------
/** Lazily create the audio engine on the first interaction (any click is a valid gesture).
 *  Returns true once the engine is ready. */
async function ensureStarted(): Promise<boolean> {
  if (engine) { await ctx!.resume(); return true; }
  try {
    $("status").textContent = "loading…";
    ctx = new AudioContext({ sampleRate: 48000 });
    await ctx.resume(); // some browsers start suspended even inside the gesture
    engine = await WasmEngine.create(ctx, { ...ENGINE_URLS, maxSources: 24 });
    engine.connect(ctx.destination);
    const roomSel = document.getElementById("room") as HTMLSelectElement | null;
    engine.setRoom(roomSel ? +roomSel.value : 2);
    const refl = document.getElementById("refl") as HTMLInputElement | null;
    engine.setReflections(refl ? refl.checked : true);
    $("status").textContent = `running @ ${ctx.sampleRate} Hz · ${engine.numRooms} rooms`;
    applyPose();
    return true;
  } catch (e) {
    $("status").textContent = "error: " + (e as Error).message;
    console.error(e);
    return false;
  }
}

($("start") as HTMLButtonElement).onclick = async () => {
  if ((await ensureStarted()) && sources.length === 0) {
    addSource({ x: 1.6, y: 0, z: -1.2 }, DEFAULT_SFX); // an audible looping starter
  }
};

// ---- sound generation -----------------------------------------------------
function sfxSamples(i: number): Float32Array {
  return SFX[i].make(ctx!.sampleRate);
}

async function addSourceAt(pos: Vec3) {
  if (await ensureStarted()) addSource(pos);
}

function addSource(pos: Vec3, forceSfx?: number) {
  if (!engine) { void ensureStarted().then((ok) => ok && addSource(pos, forceSfx)); return; }
  const sfxIndex = forceSfx ?? (document.getElementById("sfx") as HTMLSelectElement).selectedIndex;
  const s: Src = {
    id: "s" + nextId++, pos, gain: 0.8, sfx: sfxIndex, loop: SFX[sfxIndex].loop,
    color: COLORS[sources.length % COLORS.length], name: SFX[sfxIndex].name,
  };
  sources.push(s);
  engine.setSource(s.id, { samples: sfxSamples(s.sfx), gain: s.gain, pos: s.pos, loop: s.loop, play: true });
  selected = sources.length - 1;
  renderSources();
}

function reload(s: Src) {
  engine!.setSource(s.id, { samples: sfxSamples(s.sfx), gain: s.gain, pos: s.pos, loop: s.loop, play: true });
  s.name = SFX[s.sfx].name;
}

// ---- listener pose --------------------------------------------------------
let headPos: Vec3 = { x: 0, y: 0, z: 0 }; // listener position (tracked or manual height)
function applyPose() {
  headPos = tracking ? trackedPos : { x: 0, y: listenerY, z: 0 };
  engine?.setPose((orientDeg * Math.PI) / 180, headPos);
}
let trackedPos: Vec3 = { x: 0, y: 0, z: 0 };
const clampM = (v: number) => Math.max(-1.5, Math.min(1.5, v));

// ---- controls -------------------------------------------------------------
function initControls() {
  const sfxSel = $("sfx") as HTMLSelectElement;
  SFX.forEach((s) => sfxSel.add(new Option(s.name + (s.loop ? " (loop)" : ""))));
  sfxSel.selectedIndex = Math.max(0, DEFAULT_SFX); // default to an audible loop
  const roomSel = $("room") as HTMLSelectElement;
  ROOMS.forEach((r, i) => roomSel.add(new Option(r, String(i))));
  roomSel.value = "2";
  roomSel.onchange = () => engine?.setRoom(+roomSel.value);
  ($("refl") as HTMLInputElement).onchange = (e) => engine?.setReflections((e.target as HTMLInputElement).checked);
  ($("master") as HTMLInputElement).oninput = (e) => engine?.setMaster(+(e.target as HTMLInputElement).value);
  const orient = $("orient") as HTMLInputElement;
  orient.oninput = () => { orientDeg = +orient.value; $("orientVal").textContent = orientDeg + "°"; applyPose(); };
  const lisY = $("lisY") as HTMLInputElement;
  lisY.oninput = () => { listenerY = +lisY.value; applyPose(); };
  // optional webcam head-tracking — feeds yaw to the engine + the dev views
  const trackBtn = document.getElementById("track") as HTMLButtonElement | null;
  if (trackBtn) trackBtn.onclick = async (e) => {
    const btn = e.target as HTMLButtonElement;
    if (tracking) return;
    try {
      $("trackStatus").textContent = "starting camera…";
      tracker = new HeadTracker();
      await tracker.startCamera();
      $("trackStatus").textContent = "loading model…";
      await tracker.loadModel();
      tracker.startLoop(() => { $("trackStatus").textContent = "tracking — turn your head"; });
      tracking = true; btn.textContent = "Tracking ✓"; btn.disabled = true;
    } catch (err) {
      $("trackStatus").textContent = "error: " + (err as Error).message;
      console.error(err);
    }
  };
  ($("add") as HTMLButtonElement).onclick = () => addSourceAt({ x: 0, y: 0, z: -2 });
  ($("addFile") as HTMLButtonElement).onclick = async () => {
    if (await ensureStarted()) ($("file") as HTMLInputElement).click();
  };
  ($("file") as HTMLInputElement).onchange = async (e) => {
    const f = (e.target as HTMLInputElement).files?.[0];
    if (!f || !(await ensureStarted()) || !ctx || !engine) return;
    const ab = await f.arrayBuffer();
    const ad = await ctx.decodeAudioData(ab);
    const mono = ad.getChannelData(0).slice();
    const s: Src = { id: "s" + nextId++, pos: { x: 0, y: 0, z: -2 }, gain: 0.8, sfx: -1, loop: true, color: COLORS[sources.length % COLORS.length], name: f.name };
    sources.push(s);
    engine.setSource(s.id, { samples: mono as Float32Array, gain: s.gain, pos: s.pos, loop: true, play: true });
    selected = sources.length - 1; renderSources();
  };
}

function renderSources() {
  const host = $("sources");
  host.innerHTML = "";
  sources.forEach((s, i) => {
    const row = document.createElement("div");
    row.className = "src-row";
    // swatch + name select this source (clicking the controls below must NOT re-render,
    // or native <select> dropdowns close before they can open)
    const swatch = document.createElement("span");
    swatch.className = "swatch"; swatch.style.background = s.color; swatch.style.cursor = "pointer";
    const name = document.createElement("span");
    name.textContent = s.name; name.style.flex = "1"; name.style.cursor = "pointer";
    if (i === selected) name.style.fontWeight = "600";
    swatch.onclick = name.onclick = () => { selected = i; renderSources(); };

    const sel = document.createElement("select");
    SFX.forEach((x, xi) => sel.add(new Option(x.name, String(xi))));
    if (s.sfx >= 0) sel.value = String(s.sfx);
    sel.onchange = () => { s.sfx = +sel.value; s.loop = SFX[s.sfx].loop; reload(s); name.textContent = s.name; };
    const vol = document.createElement("input");
    vol.type = "range"; vol.min = "0"; vol.max = "1.5"; vol.step = "0.01"; vol.value = String(s.gain); vol.style.width = "70px";
    vol.oninput = () => { s.gain = +vol.value; engine!.setSource(s.id, { gain: s.gain }); };
    const trig = document.createElement("button"); trig.textContent = "▶";
    trig.onclick = () => engine!.trigger(s.id);
    const del = document.createElement("button"); del.textContent = "✕";
    del.onclick = () => { engine!.removeSource(s.id); sources.splice(i, 1); selected = -1; renderSources(); };
    row.append(swatch, name, sel, vol, trig, del);
    host.append(row);
  });
}

// ---- top-down map ---------------------------------------------------------
function worldToMap(p: Vec3): [number, number] {
  return [map.width / 2 + p.x * SCALE, map.height / 2 + p.z * SCALE];
}
function mapToWorld(sx: number, sy: number): Vec3 {
  return { x: (sx - map.width / 2) / SCALE, y: 0, z: (sy - map.height / 2) / SCALE };
}

let dragging = -1;
map.addEventListener("pointerdown", (e) => {
  const r = map.getBoundingClientRect();
  const sx = e.clientX - r.left, sy = e.clientY - r.top;
  for (let i = sources.length - 1; i >= 0; i--) {
    const [x, y] = worldToMap(sources[i].pos);
    if (Math.hypot(sx - x, sy - y) < 12) { dragging = i; selected = i; renderSources(); map.setPointerCapture(e.pointerId); return; }
  }
  // empty space → add (auto-starts the engine if needed)
  const w = mapToWorld(sx, sy); w.y = sources[selected]?.pos.y ?? 0;
  void addSourceAt(w);
});
map.addEventListener("pointermove", (e) => {
  if (dragging < 0) return;
  const r = map.getBoundingClientRect();
  const w = mapToWorld(e.clientX - r.left, e.clientY - r.top);
  w.y = sources[dragging].pos.y;
  sources[dragging].pos = w;
  engine?.setSource(sources[dragging].id, { pos: w });
});
map.addEventListener("pointerup", () => (dragging = -1));

function drawMap() {
  const c = mapCtx, W = map.width, H = map.height, cx = W / 2, cy = H / 2;
  c.clearRect(0, 0, W, H);
  // range rings
  c.strokeStyle = "#1d2230";
  for (let r = 1; r <= 6; r++) { c.beginPath(); c.arc(cx, cy, r * SCALE, 0, 7); c.stroke(); }
  // axes
  c.strokeStyle = "#161b27"; c.beginPath(); c.moveTo(cx, 0); c.lineTo(cx, H); c.moveTo(0, cy); c.lineTo(W, cy); c.stroke();
  c.fillStyle = "#5a6678"; c.font = "11px sans-serif";
  c.fillText("front (−z)", cx + 6, 14); c.fillText("right (+x)", W - 64, cy - 6);
  // listener (at its tracked position) + facing
  const o = (orientDeg * Math.PI) / 180;
  const fx = Math.sin(o), fz = -Math.cos(o);
  const [lx, ly] = worldToMap(headPos);
  c.strokeStyle = "#5fd0c5"; c.fillStyle = "#5fd0c5"; c.lineWidth = 2;
  c.beginPath(); c.moveTo(lx, ly); c.lineTo(lx + fx * 46, ly + fz * 46); c.stroke();
  c.beginPath(); c.arc(lx, ly, 6, 0, 7); c.fill();
  // sources
  c.lineWidth = 1;
  sources.forEach((s, i) => {
    const [x, y] = worldToMap(s.pos);
    c.fillStyle = s.color; c.globalAlpha = 0.4 + 0.6 * Math.min(1, s.gain);
    c.beginPath(); c.arc(x, y, i === selected ? 9 : 7, 0, 7); c.fill(); c.globalAlpha = 1;
    if (Math.abs(s.pos.y) > 0.05) { c.fillStyle = "#cdd3e0"; c.font = "9px sans-serif"; c.fillText("y" + s.pos.y.toFixed(1), x + 9, y); }
    if (i === selected) { c.strokeStyle = "#fff"; c.beginPath(); c.arc(x, y, 12, 0, 7); c.stroke(); }
  });
}

// ---- dev 3D head-view (oblique 3/4 projection from behind-above) -----------
const S3 = 30; // px per metre
function project3(p: Vec3): [number, number, number] {
  const cx = dev.width / 2, cy = dev.height * 0.6;
  // +x right; -z (front) → up & smaller; +y → up
  return [cx + p.x * S3, cy + p.z * S3 * 0.5 - p.y * S3, p.z];
}
function drawDev3D() {
  const c = devCtx, W = dev.width, H = dev.height;
  c.clearRect(0, 0, W, H);
  // ground grid (xz plane, y=0)
  c.strokeStyle = "#161c28"; c.lineWidth = 1;
  for (let gx = -4; gx <= 4; gx++) {
    const a = project3({ x: gx, y: 0, z: -5 }), b = project3({ x: gx, y: 0, z: 2 });
    c.beginPath(); c.moveTo(a[0], a[1]); c.lineTo(b[0], b[1]); c.stroke();
  }
  for (let gz = -5; gz <= 2; gz++) {
    const a = project3({ x: -4, y: 0, z: gz }), b = project3({ x: 4, y: 0, z: gz });
    c.beginPath(); c.moveTo(a[0], a[1]); c.lineTo(b[0], b[1]); c.stroke();
  }
  const o = (orientDeg * Math.PI) / 180;
  type Item = { sx: number; sy: number; z: number; r: number; col: string; head?: boolean };
  const items: Item[] = [];
  const hp = project3(headPos);
  items.push({ sx: hp[0], sy: hp[1], z: headPos.z, r: 9, col: "#5fd0c5", head: true });
  for (const s of sources) {
    const p = project3(s.pos);
    items.push({ sx: p[0], sy: p[1], z: s.pos.z, r: Math.max(4, Math.min(16, 9 + s.pos.z * 1.5)), col: s.color });
  }
  items.sort((a, b) => a.z - b.z); // far (front) first, near (behind) last
  for (const it of items) {
    c.fillStyle = it.col; c.globalAlpha = 0.9;
    c.beginPath(); c.arc(it.sx, it.sy, it.r, 0, 7); c.fill(); c.globalAlpha = 1;
    if (it.head) {
      const tip = project3({ x: headPos.x + Math.sin(o) * 1.4, y: headPos.y, z: headPos.z - Math.cos(o) * 1.4 });
      c.strokeStyle = "#5fd0c5"; c.lineWidth = 2;
      c.beginPath(); c.moveTo(it.sx, it.sy); c.lineTo(tip[0], tip[1]); c.stroke();
    }
  }
  c.fillStyle = "#7c8499"; c.font = "11px sans-serif";
  c.fillText("dev: head (teal, with facing) + sources — front is up, behind is down", 10, H - 8);
}

function frame() {
  if (tracking && tracker) {
    // camera is mirrored → negate yaw so turning right faces right; position is 6DoF
    orientDeg = Math.max(-180, Math.min(180, -tracker.yaw));
    const p = tracker.pos;
    trackedPos = { x: clampM(p.x), y: clampM(p.y), z: clampM(-p.z) }; // +z(toward cam)→front(−z)
    ($("orient") as HTMLInputElement).value = String(Math.round(orientDeg));
    $("orientVal").textContent = Math.round(orientDeg) + "°";
    applyPose();
  }
  drawMap();
  if (DEV3D) drawDev3D();
  requestAnimationFrame(frame);
}

// ---- boot -----------------------------------------------------------------
initControls();
if (DEV3D) { dev.style.display = "block"; }
renderSources();
frame();
