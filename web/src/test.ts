// Chamber renderer test harness. Place sources in space, pick a sci-fi sound + volume,
// move the listener, switch rooms/reflections — all driving the wasm binaural engine.
// A dev 3D head-view (──flag CHAMBER_DEV=1, `just harness-dev`) shows where we think the
// listener's head is, in 3D, alongside the sources.

import { WasmEngine, ENGINE_URLS, type Vec3 } from "./audio/wasmEngine";
import { SFX } from "./audio/sfx";

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
const SCALE = 36; // px per metre on the top-down map

// ---- audio setup ----------------------------------------------------------
($("start") as HTMLButtonElement).onclick = async () => {
  if (engine) { await ctx!.resume(); return; }
  $("status").textContent = "loading…";
  ctx = new AudioContext({ sampleRate: 48000 });
  engine = await WasmEngine.create(ctx, { ...ENGINE_URLS, maxSources: 24 });
  engine.connect(ctx.destination);
  engine.setRoom(2); // hall
  engine.setReflections(true);
  $("status").textContent = `running @ ${ctx.sampleRate} Hz · ${engine.numRooms} rooms`;
  applyPose();
  // a starter source so there's something to hear
  addSource({ x: 1.6, y: 0, z: -1.2 });
};

// ---- sound generation -----------------------------------------------------
function sfxSamples(i: number): Float32Array {
  return SFX[i].make(ctx!.sampleRate);
}

function addSource(pos: Vec3) {
  if (!engine) { $("status").textContent = "press Start first"; return; }
  const sfxIndex = (document.getElementById("sfx") as HTMLSelectElement).selectedIndex;
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
function applyPose() {
  engine?.setPose((orientDeg * Math.PI) / 180, { x: 0, y: listenerY, z: 0 });
}

// ---- controls -------------------------------------------------------------
function initControls() {
  const sfxSel = $("sfx") as HTMLSelectElement;
  SFX.forEach((s) => sfxSel.add(new Option(s.name + (s.loop ? " (loop)" : ""))));
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
  ($("add") as HTMLButtonElement).onclick = () => addSource({ x: 0, y: 0, z: -2 });
  ($("addFile") as HTMLButtonElement).onclick = () => ($("file") as HTMLInputElement).click();
  ($("file") as HTMLInputElement).onchange = async (e) => {
    const f = (e.target as HTMLInputElement).files?.[0];
    if (!f || !ctx || !engine) return;
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
    row.innerHTML = `<span class="swatch" style="background:${s.color}"></span>
      <span style="flex:1;${i === selected ? "font-weight:600" : ""}">${s.name}</span>`;
    const sel = document.createElement("select");
    SFX.forEach((x, xi) => sel.add(new Option(x.name, String(xi))));
    if (s.sfx >= 0) sel.value = String(s.sfx);
    sel.onchange = () => { s.sfx = +sel.value; s.loop = SFX[s.sfx].loop; reload(s); renderSources(); };
    const vol = document.createElement("input");
    vol.type = "range"; vol.min = "0"; vol.max = "1.5"; vol.step = "0.01"; vol.value = String(s.gain); vol.style.width = "70px";
    vol.oninput = () => { s.gain = +vol.value; engine!.setSource(s.id, { gain: s.gain }); };
    const trig = document.createElement("button"); trig.textContent = "▶";
    trig.onclick = () => engine!.trigger(s.id);
    const del = document.createElement("button"); del.textContent = "✕";
    del.onclick = () => { engine!.removeSource(s.id); sources.splice(i, 1); selected = -1; renderSources(); };
    row.append(sel, vol, trig, del);
    row.onclick = () => { selected = i; renderSources(); };
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
  // empty space → add
  const w = mapToWorld(sx, sy); w.y = sources[selected]?.pos.y ?? 0;
  addSource(w);
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
  // listener + facing
  const o = (orientDeg * Math.PI) / 180;
  const fx = Math.sin(o), fz = -Math.cos(o);
  c.strokeStyle = "#5fd0c5"; c.fillStyle = "#5fd0c5"; c.lineWidth = 2;
  c.beginPath(); c.moveTo(cx, cy); c.lineTo(cx + fx * 46, cy + fz * 46); c.stroke();
  c.beginPath(); c.arc(cx, cy, 6, 0, 7); c.fill();
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

// ---- dev 3D head-view -----------------------------------------------------
function drawDev3D() {
  const c = devCtx, W = dev.width, H = dev.height;
  c.clearRect(0, 0, W, H);
  // camera: above and behind the listener (at origin), looking toward −z (front)
  const camPos = { x: 0, y: 2.2, z: 3.4 };
  const f = 320; // focal
  const project = (p: Vec3): [number, number, number] | null => {
    const x = p.x - camPos.x, y = p.y - camPos.y, z = p.z - camPos.z;
    const zc = -z; // distance in front of camera (camera looks toward −z)
    if (zc <= 0.05) return null;
    return [W / 2 + (x * f) / zc, H / 2 - ((y + 0.4) * f) / zc, zc];
  };
  // ground grid (xz plane at y=0)
  c.strokeStyle = "#1a2030"; c.lineWidth = 1;
  for (let gx = -4; gx <= 4; gx++) {
    const a = project({ x: gx, y: 0, z: -6 }), b = project({ x: gx, y: 0, z: 0.5 });
    if (a && b) { c.beginPath(); c.moveTo(a[0], a[1]); c.lineTo(b[0], b[1]); c.stroke(); }
  }
  for (let gz = -6; gz <= 0; gz++) {
    const a = project({ x: -4, y: 0, z: gz }), b = project({ x: 4, y: 0, z: gz });
    if (a && b) { c.beginPath(); c.moveTo(a[0], a[1]); c.lineTo(b[0], b[1]); c.stroke(); }
  }
  // collect drawables (head + sources), painter's sort by depth
  const items: { p: [number, number, number]; r: number; col: string; head?: boolean }[] = [];
  const head = project({ x: 0, y: listenerY, z: 0 });
  if (head) items.push({ p: head, r: 16, col: "#5fd0c5", head: true });
  for (const s of sources) { const p = project(s.pos); if (p) items.push({ p, r: 10, col: s.color }); }
  items.sort((a, b) => b.p[2] - a.p[2]);
  const o = (orientDeg * Math.PI) / 180;
  for (const it of items) {
    const [sx, sy, zc] = it.p;
    const rr = (it.r * 320) / zc / 12;
    c.fillStyle = it.col; c.globalAlpha = 0.85; c.beginPath(); c.arc(sx, sy, Math.max(2, rr), 0, 7); c.fill(); c.globalAlpha = 1;
    if (it.head) {
      // facing arrow on the ground
      const tip = project({ x: Math.sin(o) * 1.0, y: listenerY, z: -Math.cos(o) * 1.0 });
      if (tip) { c.strokeStyle = "#5fd0c5"; c.lineWidth = 2; c.beginPath(); c.moveTo(sx, sy); c.lineTo(tip[0], tip[1]); c.stroke(); }
    }
  }
  c.fillStyle = "#7c8499"; c.font = "11px sans-serif";
  c.fillText("dev: estimated head (teal) + sources, looking from behind", 10, H - 8);
}

function frame() {
  drawMap();
  if (DEV3D) drawDev3D();
  requestAnimationFrame(frame);
}

// ---- boot -----------------------------------------------------------------
initControls();
if (DEV3D) { dev.style.display = "block"; }
renderSources();
frame();
