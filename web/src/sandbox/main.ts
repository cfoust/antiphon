// Antiphon sandbox — the unified dev/experimentation tool. Merges the old test harness
// (source placement, SFX/voices, file loading, head tracking), arp-lab (the arpeggio-bloom
// synth with its full parameter panel) and attention-demo (the in-engine cue) into one
// 3D scene editor driving the wasm binaural engine: place sources, aim them (directivity),
// inflate them (extent), loop them, shape the room, and optionally let your eyes drive the
// immersion fade (off by default so experiments aren't gated on the webcam).

import { WasmEngine, ENGINE_URLS, type Vec3, type RoomDims } from "../audio/wasmEngine";
import { SFX } from "../audio/sfx";
import { HeadTracker } from "../tracking/headTracking";
import { SceneView, type DoorSpec } from "./scene3d";
import { ARP_DEFAULTS, SCALES, buildArpCycle, arpEff, rootHz, noteName, type ArpParams, type ArpDirection } from "./arp";

const ROOMS = ["dry", "room", "hall", "cathedral", "room (BRIR)", "hall (BRIR)"];
const VOICES = ["atlas", "echo", "wren", "cass", "iris", "rook"];
const COLORS = ["#7aa2ff", "#5fd0c5", "#ffce6b", "#c08bff", "#ff9d7a", "#9aa6b8", "#6be4a0", "#e46b9a"];

interface SandboxSource {
  id: string;
  name: string;
  kind: string; // "sfx:<i>" | "voice:<id>" | "file:<name>" | "arp"
  pos: Vec3;
  gain: number;
  send: number;
  loop: boolean;
  playing: boolean;
  directivity: number;
  facingYaw: number; // deg, 0 = facing front (−z), world frame
  facingPitch: number; // deg, + up
  extent: number; // metres
  color: string;
  arp?: ArpParams;
}

/** Doorway experiment: a rectangular aperture on one wall of the room. */
interface DoorConfig extends DoorSpec {
  enabled: boolean;
}
const DOOR_DEFAULTS: DoorConfig = { enabled: false, wall: "-z", along: 0, width: 2.5, height: 3.0 };

interface SceneFile {
  sources: Omit<SandboxSource, "id">[];
  room: number;
  reflections: boolean;
  reverbBlend: number;
  master: number;
  fit: number;
  attnAgents: number;
  attnBuildMin: number;
  immersion: number;
  orientDeg: number;
  listenerY: number;
  door?: DoorConfig;
}

const $ = (id: string) => document.getElementById(id)!;

// ---- state ------------------------------------------------------------------
let engine: WasmEngine | null = null;
let ctx: AudioContext | null = null;
const sources: SandboxSource[] = [];
let selected: string | null = null;
let nextId = 1;

let orientDeg = 0;
let listenerY = 0;
let tracking = false;
let tracker: HeadTracker | null = null;
let trackedPos: Vec3 = { x: 0, y: 0, z: 0 };
let headPos: Vec3 = { x: 0, y: 0, z: 0 };

let roomIdx = 4; // room (BRIR) — the default that sounded best
let roomDims: RoomDims | null = null; // fetched from the engine (antiphon_room_dims)
let door: DoorConfig = { ...DOOR_DEFAULTS };
let reflections = true;
let reverbBlend = 1;
let master = 0.9;
let fit = 1.0;
let attnAgents = 0;
let attnBuildMin = 1.0;
let eyeFade = false; // OFF by default: immersion is manual so experiments aren't camera-gated
let immersion = 1.0; // manual target (scene full, cue silent)

const fileLib = new Map<string, Float32Array>(); // uploaded audio by name (not persisted)
const view = new SceneView($("view") as HTMLCanvasElement);

// ---- engine -----------------------------------------------------------------
async function ensureStarted(): Promise<boolean> {
  if (engine) {
    await ctx!.resume();
    return true;
  }
  try {
    setStatus("loading engine…");
    ctx = new AudioContext({ sampleRate: 48000 });
    await ctx.resume();
    engine = await WasmEngine.create(ctx, { ...ENGINE_URLS, maxSources: 24 });
    engine.connect(ctx.destination);
    engine.setRoom(roomIdx);
    engine.setReflections(reflections);
    engine.setReverbBlend(reverbBlend);
    engine.setMaster(master);
    engine.setFreqScale(fit);
    engine.setAttentionAgents(attnAgents);
    engine.setAttentionBuildMinutes(attnBuildMin);
    engine.setImmersionEngine(immersion);
    applyPose();
    await syncRoomGeom();
    for (const s of sources) await pushSource(s, true); // restore a loaded scene
    setStatus(`running @ ${ctx.sampleRate} Hz · ${engine.numRooms} rooms`);
    return true;
  } catch (e) {
    setStatus("error: " + (e as Error).message);
    console.error(e);
    return false;
  }
}

/** Pull the current room's true geometry from the engine and redraw the room + door. */
async function syncRoomGeom(): Promise<void> {
  roomDims = engine ? await engine.roomDims(roomIdx) : null;
  view.setRoom(roomDims);
  view.setDoor(door.enabled ? door : null);
  const hint = document.getElementById("roomDimsHint");
  if (hint) hint.textContent = roomDimsText();
}

function roomDimsText(): string {
  return roomDims
    ? `${roomDims.w.toFixed(1)} × ${roomDims.h.toFixed(1)} × ${roomDims.d.toFixed(1)} m · ears ${roomDims.earHeight.toFixed(1)} m above the floor`
    : "room dims shown once the engine starts";
}

/** Where a source snapped "to the doorway" goes: 0.5 m inside the aperture, vertically
 *  centred in it, facing into the room (yaw in degrees, engine convention: 0 = −z). */
function doorwayPose(): { pos: Vec3; yaw: number } | null {
  if (!roomDims) return null;
  const b = roomDims;
  const yc = -b.earHeight + Math.min(door.height, b.h) / 2;
  let pos: Vec3;
  let n: { x: number; z: number }; // inward wall normal
  switch (door.wall) {
    case "-z": pos = { x: door.along, y: yc, z: -b.d / 2 + 0.5 }; n = { x: 0, z: 1 }; break;
    case "+z": pos = { x: door.along, y: yc, z: b.d / 2 - 0.5 }; n = { x: 0, z: -1 }; break;
    case "-x": pos = { x: -b.w / 2 + 0.5, y: yc, z: door.along }; n = { x: 1, z: 0 }; break;
    case "+x": pos = { x: b.w / 2 - 0.5, y: yc, z: door.along }; n = { x: -1, z: 0 }; break;
  }
  return { pos, yaw: (Math.atan2(n.x, -n.z) * 180) / Math.PI };
}

function facingVec(s: SandboxSource): Vec3 {
  const y = (s.facingYaw * Math.PI) / 180;
  const p = (s.facingPitch * Math.PI) / 180;
  return { x: Math.sin(y) * Math.cos(p), y: Math.sin(p), z: -Math.cos(y) * Math.cos(p) };
}

async function sourceSamples(s: SandboxSource): Promise<Float32Array | null> {
  const [kind, arg] = s.kind.split(":");
  if (kind === "sfx") return SFX[+arg].make(48000);
  if (kind === "arp") return buildArpCycle(s.arp ?? ARP_DEFAULTS);
  if (kind === "voice") {
    const ab = await fetch(`audio/${arg}.mp3`).then((r) => r.arrayBuffer());
    const ad = await ctx!.decodeAudioData(ab);
    return ad.getChannelData(0).slice() as Float32Array;
  }
  if (kind === "file") return fileLib.get(arg) ?? null; // null after scene reload — re-load the file
  return null;
}

/** Push a source's full state (and optionally fresh samples) to the engine. */
async function pushSource(s: SandboxSource, withSamples = false): Promise<void> {
  if (!engine) return;
  const gain = s.kind === "arp" ? arpEff(s.arp ?? ARP_DEFAULTS).gain * (s.gain / 0.6) : s.gain;
  const opts: Parameters<WasmEngine["setSource"]>[1] = {
    gain,
    pos: s.pos,
    send: s.send,
    facing: s.directivity > 0 ? facingVec(s) : { x: 0, y: 0, z: 0 },
    directivity: s.directivity,
    extent: s.extent,
    loop: s.loop,
  };
  if (withSamples) {
    const samples = await sourceSamples(s);
    if (samples) {
      opts.samples = samples;
      opts.play = s.playing;
    }
  }
  engine.setSource(s.id, opts);
}

// ---- sound library ----------------------------------------------------------
function soundOptions(): { kind: string; label: string }[] {
  return [
    ...SFX.map((s, i) => ({ kind: `sfx:${i}`, label: s.name + (s.loop ? " (loop)" : "") })),
    ...VOICES.map((v) => ({ kind: `voice:${v}`, label: `${v} (voice)` })),
    { kind: "arp", label: "ARP synth (agent cue)" },
    ...[...fileLib.keys()].map((n) => ({ kind: `file:${n}`, label: `📄 ${n}` })),
  ];
}
function soundLabel(kind: string): string {
  return soundOptions().find((o) => o.kind === kind)?.label ?? kind;
}
function soundLoops(kind: string): boolean {
  const [k, arg] = kind.split(":");
  if (k === "sfx") return SFX[+arg].loop;
  return true;
}

// ---- source CRUD ------------------------------------------------------------
async function addSource(pos: Vec3, kind?: string): Promise<void> {
  if (!(await ensureStarted())) return;
  const k = kind ?? (($("newSound") as HTMLSelectElement).value || "sfx:6");
  const s: SandboxSource = {
    id: "s" + nextId++,
    name: soundLabel(k),
    kind: k,
    pos,
    gain: 0.6,
    send: 0.3,
    loop: soundLoops(k),
    playing: true,
    directivity: 0,
    facingYaw: 0,
    facingPitch: 0,
    extent: 0,
    color: COLORS[sources.length % COLORS.length],
    arp: k === "arp" ? structuredClone(ARP_DEFAULTS) : undefined,
  };
  sources.push(s);
  selected = s.id;
  switchTab("source");
  await pushSource(s, true);
  refreshUI();
  saveSoon();
}

function removeSource(id: string): void {
  const i = sources.findIndex((s) => s.id === id);
  if (i < 0) return;
  engine?.removeSource(id);
  sources.splice(i, 1);
  if (selected === id) selected = null;
  refreshUI();
  saveSoon();
}

function sel(): SandboxSource | null {
  return sources.find((s) => s.id === selected) ?? null;
}

// ---- pose / tracking ---------------------------------------------------------
function applyPose(): void {
  headPos = tracking ? { ...trackedPos, y: trackedPos.y + listenerY } : { x: 0, y: listenerY, z: 0 };
  engine?.setPose((orientDeg * Math.PI) / 180, headPos);
}

const clampM = (v: number) => Math.max(-1.5, Math.min(1.5, v));

async function startTracking(btn: HTMLButtonElement): Promise<void> {
  if (tracking) return;
  try {
    $("trackStatus").textContent = "starting camera…";
    tracker = new HeadTracker();
    await tracker.startCamera();
    $("trackStatus").textContent = "loading model…";
    await tracker.loadModel();
    tracker.startLoop(() => ($("trackStatus").textContent = "tracking — turn your head"));
    tracking = true;
    btn.textContent = "Tracking ✓";
    btn.disabled = false;
    btn.textContent = "Re-center";
    btn.onclick = () => tracker?.setNeutral();
  } catch (err) {
    $("trackStatus").textContent = "error: " + (err as Error).message;
    console.error(err);
  }
}

// ---- immersion ----------------------------------------------------------------
function applyImmersion(): void {
  const target = eyeFade && tracker ? (tracker.eyesClosed ? 1 : 0) : immersion;
  engine?.setImmersionEngine(target);
}

// ---- persistence ---------------------------------------------------------------
const STORE_KEY = "antiphon-sandbox-scene";
let saveTimer: number | undefined;
function saveSoon(): void {
  clearTimeout(saveTimer);
  saveTimer = window.setTimeout(() => localStorage.setItem(STORE_KEY, JSON.stringify(sceneToJson())), 400);
}
function sceneToJson(): SceneFile {
  return {
    sources: sources.map(({ id: _id, ...rest }) => rest),
    room: roomIdx, reflections, reverbBlend, master, fit,
    attnAgents, attnBuildMin, immersion, orientDeg, listenerY,
    door,
  };
}
function loadScene(j: SceneFile): void {
  for (const s of sources) engine?.removeSource(s.id);
  sources.length = 0;
  selected = null;
  for (const src of j.sources ?? []) {
    sources.push({ ...src, id: "s" + nextId++ });
  }
  roomIdx = j.room ?? 4;
  reflections = j.reflections ?? true;
  reverbBlend = j.reverbBlend ?? 1;
  master = j.master ?? 0.9;
  fit = j.fit ?? 1;
  attnAgents = j.attnAgents ?? 0;
  attnBuildMin = j.attnBuildMin ?? 1;
  immersion = j.immersion ?? 1;
  orientDeg = j.orientDeg ?? 0;
  listenerY = j.listenerY ?? 0;
  door = { ...DOOR_DEFAULTS, ...(j.door ?? {}) };
  void syncRoomGeom();
  if (engine) {
    engine.setRoom(roomIdx);
    engine.setReflections(reflections);
    engine.setReverbBlend(reverbBlend);
    engine.setMaster(master);
    engine.setFreqScale(fit);
    engine.setAttentionAgents(attnAgents);
    engine.setAttentionBuildMinutes(attnBuildMin);
    applyImmersion();
    applyPose();
    void (async () => {
      for (const s of sources) await pushSource(s, true);
    })();
  }
  refreshUI();
  refreshGlobals();
}

// ---- generic UI builders --------------------------------------------------------
interface SliderSpec {
  label: string;
  min: number;
  max: number;
  step: number;
  value: number;
  fmt?: (v: number) => string;
  onInput: (v: number) => void;
}
function slider(spec: SliderSpec): HTMLDivElement {
  const row = document.createElement("div");
  row.className = "row";
  const lab = document.createElement("label");
  const name = document.createElement("span");
  name.className = "name";
  name.textContent = spec.label;
  const val = document.createElement("span");
  val.className = "val";
  const show = (v: number) => (val.textContent = spec.fmt ? spec.fmt(v) : String(Math.round(v * 100) / 100));
  show(spec.value);
  lab.append(name, val);
  const inp = document.createElement("input");
  inp.type = "range";
  inp.min = String(spec.min);
  inp.max = String(spec.max);
  inp.step = String(spec.step);
  inp.value = String(spec.value);
  inp.oninput = () => {
    const v = +inp.value;
    show(v);
    spec.onInput(v);
  };
  row.append(lab, inp);
  return row;
}

function segButtons<T extends string>(values: T[], cur: T, onPick: (v: T) => void): HTMLDivElement {
  const box = document.createElement("div");
  box.className = "seg";
  for (const v of values) {
    const b = document.createElement("button");
    b.textContent = v;
    if (v === cur) b.classList.add("on");
    b.onclick = () => {
      box.querySelectorAll("button").forEach((x) => x.classList.remove("on"));
      b.classList.add("on");
      onPick(v);
    };
    box.append(b);
  }
  return box;
}

// ---- source list + inspector ------------------------------------------------------
function refreshUI(): void {
  renderSourceList();
  renderInspector();
  syncView();
}

function syncView(): void {
  view.sync(
    sources.map((s) => ({
      id: s.id, name: s.name, pos: s.pos, color: s.color, directivity: s.directivity,
      facing: facingVec(s), extent: s.extent, playing: s.playing,
    })),
  );
  view.setSelected(selected);
}

function renderSourceList(): void {
  const host = $("sources");
  host.innerHTML = "";
  if (!sources.length) {
    host.innerHTML = `<div class="hint">Double-click the floor to add a source, or use ＋.</div>`;
    return;
  }
  for (const s of sources) {
    const row = document.createElement("div");
    row.className = "src-row" + (s.id === selected ? " sel" : "");
    const swatch = document.createElement("span");
    swatch.className = "swatch";
    swatch.style.background = s.color;
    const name = document.createElement("span");
    name.className = "src-name";
    name.textContent = s.name;
    const play = document.createElement("button");
    play.textContent = s.playing ? "❚❚" : "▶";
    play.onclick = (e) => {
      e.stopPropagation();
      s.playing = !s.playing;
      if (s.playing) engine?.setSource(s.id, { play: true });
      else engine?.stopSource(s.id);
      refreshUI();
      saveSoon();
    };
    const del = document.createElement("button");
    del.textContent = "✕";
    del.onclick = (e) => {
      e.stopPropagation();
      removeSource(s.id);
    };
    row.onclick = () => {
      selected = s.id;
      switchTab("source");
      refreshUI();
    };
    row.append(swatch, name, play, del);
    host.append(row);
  }
}

function renderInspector(): void {
  const host = $("inspector");
  host.innerHTML = "";
  const s = sel();
  $("noSel").style.display = s ? "none" : "";
  $("arpPanel").style.display = s?.kind === "arp" ? "" : "none";
  if (!s) return;

  // sound picker
  const soundSel = document.createElement("select");
  for (const o of soundOptions()) soundSel.add(new Option(o.label, o.kind));
  soundSel.value = s.kind;
  soundSel.onchange = () => {
    s.kind = soundSel.value;
    s.name = soundLabel(s.kind);
    s.loop = soundLoops(s.kind);
    if (s.kind === "arp" && !s.arp) s.arp = structuredClone(ARP_DEFAULTS);
    void pushSource(s, true);
    refreshUI();
    saveSoon();
  };
  host.append(soundSel);

  // range covers the hall's 10.4 m ceiling and dips below the floor (outside-the-room experiments)
  const heightRow = slider({ label: "Height (y)", min: -4, max: 12, step: 0.01, value: s.pos.y, fmt: (v) => v.toFixed(2) + " m", onInput: (v) => { s.pos = { ...s.pos, y: v }; void pushSource(s); syncView(); saveSoon(); } });
  (heightRow.querySelector("input") as HTMLInputElement).id = "heightSlider";
  host.append(
    slider({ label: "Volume", min: 0, max: 1.5, step: 0.01, value: s.gain, onInput: (v) => { s.gain = v; void pushSource(s); saveSoon(); } }),
    slider({ label: "Reverb send", min: 0, max: 1, step: 0.01, value: s.send, onInput: (v) => { s.send = v; void pushSource(s); saveSoon(); } }),
    heightRow,
  );

  // loop + trigger
  const rowLT = document.createElement("div");
  rowLT.className = "btnrow";
  const loop = document.createElement("label");
  loop.className = "toggle";
  const loopCb = document.createElement("input");
  loopCb.type = "checkbox";
  loopCb.checked = s.loop;
  loopCb.onchange = () => {
    s.loop = loopCb.checked;
    void pushSource(s);
    saveSoon();
  };
  loop.append(loopCb, document.createTextNode(" loop"));
  const trig = document.createElement("button");
  trig.textContent = "▶ trigger";
  trig.onclick = () => engine?.trigger(s.id);
  rowLT.append(loop, trig);
  host.append(rowLT);

  // directivity block
  const dHead = document.createElement("div");
  dHead.className = "subhead";
  dHead.textContent = "Directivity";
  host.append(
    dHead,
    slider({ label: "Amount (omni → cardioid)", min: 0, max: 1, step: 0.01, value: s.directivity, onInput: (v) => { s.directivity = v; void pushSource(s); syncView(); saveSoon(); } }),
    slider({ label: "Facing yaw", min: -180, max: 180, step: 1, value: s.facingYaw, fmt: (v) => v.toFixed(0) + "°", onInput: (v) => { s.facingYaw = v; void pushSource(s); syncView(); saveSoon(); } }),
    slider({ label: "Facing pitch", min: -80, max: 80, step: 1, value: s.facingPitch, fmt: (v) => v.toFixed(0) + "°", onInput: (v) => { s.facingPitch = v; void pushSource(s); syncView(); saveSoon(); } }),
  );
  const aim = document.createElement("button");
  aim.textContent = "🎯 aim at listener";
  aim.onclick = () => {
    const d = { x: headPos.x - s.pos.x, y: headPos.y - s.pos.y, z: headPos.z - s.pos.z };
    const len = Math.hypot(d.x, d.y, d.z) || 1;
    s.facingYaw = (Math.atan2(d.x, -d.z) * 180) / Math.PI;
    s.facingPitch = (Math.asin(d.y / len) * 180) / Math.PI;
    if (s.directivity === 0) s.directivity = 0.7;
    void pushSource(s);
    refreshUI();
    saveSoon();
  };
  // doorway snap: 0.5 m inside the aperture, centred in it, radiating into the room,
  // wide extent + hot reverb send — the "voice coming through a doorway" preset.
  const toDoor = document.createElement("button");
  toDoor.textContent = "🚪 → doorway";
  toDoor.title = "snap into the door aperture, facing into the room (needs the engine running)";
  toDoor.onclick = () => {
    const dp = doorwayPose();
    if (!dp) return;
    if (!door.enabled) {
      door.enabled = true;
      view.setDoor(door);
      refreshGlobals();
    }
    s.pos = dp.pos;
    s.facingYaw = dp.yaw;
    s.facingPitch = 0;
    if (s.directivity === 0) s.directivity = 0.7;
    s.extent = 1.2;
    s.send = 0.8;
    void pushSource(s);
    refreshUI();
    saveSoon();
  };
  const aimRow = document.createElement("div");
  aimRow.className = "btnrow";
  aimRow.append(aim, toDoor);
  host.append(aimRow);

  // extent block
  const eHead = document.createElement("div");
  eHead.className = "subhead";
  eHead.textContent = "Volumetric extent";
  host.append(
    eHead,
    slider({ label: "Radius", min: 0, max: 4, step: 0.05, value: s.extent, fmt: (v) => (v === 0 ? "point" : v.toFixed(2) + " m"), onInput: (v) => { s.extent = v; void pushSource(s); syncView(); saveSoon(); } }),
  );

  const posRow = document.createElement("div");
  posRow.className = "hint";
  posRow.textContent = `position: x ${s.pos.x.toFixed(2)}  y ${s.pos.y.toFixed(2)}  z ${s.pos.z.toFixed(2)} (drag in the 3D view)`;
  posRow.id = "posReadout";
  host.append(posRow);

  renderArpPanel(s);
}

// ---- arp panel -----------------------------------------------------------------
let arpRebuildTimer: number | undefined;
function arpRebuildSoon(s: SandboxSource): void {
  clearTimeout(arpRebuildTimer);
  arpRebuildTimer = window.setTimeout(() => void pushSource(s, true), 120);
}

function renderArpPanel(s: SandboxSource): void {
  const host = $("arp");
  host.innerHTML = "";
  if (s.kind !== "arp") return;
  const p = (s.arp ??= structuredClone(ARP_DEFAULTS));
  const upd = (fn: () => void, rebuild = true) => {
    fn();
    if (rebuild) arpRebuildSoon(s);
    else void pushSource(s);
    saveSoon();
  };

  const mk = (label: string, min: number, max: number, step: number, get: () => number, set: (v: number) => void, fmt?: (v: number) => string, rebuild = true) =>
    slider({ label, min, max, step, value: get(), fmt, onInput: (v) => upd(() => set(v), rebuild) });

  host.append(
    mk("Cycle period", 0.5, 12, 0.1, () => p.cyclePeriod, (v) => (p.cyclePeriod = v), (v) => v.toFixed(1) + " s"),
    mk("Notes / voices", 1, 8, 1, () => p.noteCount, (v) => (p.noteCount = v), (v) => v.toFixed(0)),
    mk("Note spacing", 0.02, 0.6, 0.005, () => p.stride, (v) => (p.stride = v), (v) => v.toFixed(3) + " s"),
    mk("Humanize", 0, 0.08, 0.002, () => p.humanize, (v) => (p.humanize = v), (v) => v.toFixed(3) + " s"),
  );
  const dirLab = document.createElement("div");
  dirLab.className = "subhead";
  dirLab.textContent = "Direction";
  host.append(dirLab, segButtons<ArpDirection>(["up", "down", "updown", "random"], p.direction, (v) => upd(() => (p.direction = v))));

  host.append(
    mk("Attack (bloom)", 0.005, 2, 0.005, () => p.attack, (v) => (p.attack = v), (v) => v.toFixed(3) + " s"),
    mk("Decay (ring)", 0.2, 5, 0.05, () => p.decay, (v) => (p.decay = v), (v) => v.toFixed(2) + " s"),
    mk("Brightness", 1, 8, 1, () => p.brightness, (v) => (p.brightness = v), (v) => v.toFixed(0) + " partials"),
    mk("Detune", 0, 0.01, 0.0005, () => p.detune, (v) => (p.detune = v), (v) => (v * 1000).toFixed(1) + "‰"),
    mk("Tremolo rate", 0, 8, 0.1, () => p.tremRate, (v) => (p.tremRate = v), (v) => v.toFixed(1) + " Hz"),
    mk("Tremolo depth", 0, 0.4, 0.01, () => p.tremDepth, (v) => (p.tremDepth = v)),
    mk("Root note", 0, 24, 1, () => p.rootSemi, (v) => (p.rootSemi = v), () => `${noteName(rootHz(p))} · ${rootHz(p).toFixed(0)} Hz`),
  );

  const scaleSel = document.createElement("select");
  for (const k of Object.keys(SCALES)) scaleSel.add(new Option(k, k));
  scaleSel.value = p.scale;
  scaleSel.onchange = () => upd(() => (p.scale = scaleSel.value));
  host.append(scaleSel);

  host.append(
    mk("Warmth (low-pass)", 800, 16000, 100, () => p.warmth, (v) => (p.warmth = v), (v) => v.toFixed(0) + " Hz"),
    mk("Gain", 0, 0.4, 0.005, () => p.gain, (v) => (p.gain = v), undefined, false),
    mk("Urgency", 0, 1, 0.01, () => p.urgency, (v) => (p.urgency = v)),
    mk("Build time", 0.1, 10, 0.1, () => p.buildMinutes, (v) => (p.buildMinutes = v), (v) => v.toFixed(1) + " min", false),
  );

  const btns = document.createElement("div");
  btns.className = "btnrow";
  const reroll = document.createElement("button");
  reroll.textContent = "⟳ re-roll";
  reroll.onclick = () => void pushSource(s, true);
  const auto = document.createElement("button");
  auto.textContent = "⏱ auto-build";
  let autoOn = false;
  let buildStart: number | null = null;
  const tickBuild = (ts: number) => {
    if (!autoOn || sel() !== s) return;
    if (buildStart == null) buildStart = ts;
    p.urgency = Math.min(1, (ts - buildStart) / 1000 / (p.buildMinutes * 60));
    arpRebuildSoon(s);
    if (p.urgency < 1) requestAnimationFrame(tickBuild);
    else {
      autoOn = false;
      auto.classList.remove("on");
      renderArpPanel(s);
    }
  };
  auto.onclick = () => {
    autoOn = !autoOn;
    auto.classList.toggle("on", autoOn);
    buildStart = null;
    if (autoOn) requestAnimationFrame(tickBuild);
  };
  const reset = document.createElement("button");
  reset.textContent = "↺ reset to P3";
  reset.onclick = () => {
    s.arp = structuredClone(ARP_DEFAULTS);
    void pushSource(s, true);
    renderArpPanel(s);
    saveSoon();
  };
  btns.append(reroll, auto, reset);
  host.append(btns);
}

// ---- global panels ---------------------------------------------------------------
function refreshGlobals(): void {
  $("listenerPanelBody").innerHTML = "";
  $("roomPanelBody").innerHTML = "";
  $("attnPanelBody").innerHTML = "";
  buildListenerPanel();
  buildRoomPanel();
  buildAttnPanel();
}

function buildListenerPanel(): void {
  const host = $("listenerPanelBody");
  const yawRow = slider({
    label: "Head yaw", min: -180, max: 180, step: 1, value: orientDeg,
    fmt: (v) => v.toFixed(0) + "°",
    onInput: (v) => { orientDeg = v; applyPose(); },
  });
  (yawRow.querySelector("input") as HTMLInputElement).id = "yawSlider";
  host.append(
    yawRow,
    slider({ label: "Height (y)", min: -0.5, max: 0.5, step: 0.01, value: listenerY, fmt: (v) => v.toFixed(2) + " m", onInput: (v) => { listenerY = v; applyPose(); saveSoon(); } }),
  );

  const trackBtn = document.createElement("button");
  trackBtn.textContent = "📷 Start head tracking";
  trackBtn.onclick = () => void startTracking(trackBtn);
  const trackStatus = document.createElement("span");
  trackStatus.className = "hint";
  trackStatus.id = "trackStatus";
  trackStatus.textContent = "camera off";
  const row = document.createElement("div");
  row.className = "btnrow";
  row.append(trackBtn, trackStatus);
  host.append(row);

  // eyes + immersion
  const eyeRow = document.createElement("div");
  eyeRow.className = "btnrow";
  const eyeState = document.createElement("span");
  eyeState.id = "eyeState";
  eyeState.className = "hint";
  eyeState.textContent = "eyes: —";
  const meter = document.createElement("progress");
  meter.id = "eyeMeter";
  meter.max = 1;
  meter.value = 1;
  eyeRow.append(eyeState, meter);
  host.append(eyeRow);

  const fadeToggle = document.createElement("label");
  fadeToggle.className = "toggle";
  const cb = document.createElement("input");
  cb.type = "checkbox";
  cb.checked = eyeFade;
  cb.onchange = () => {
    eyeFade = cb.checked;
    immSlider.style.opacity = eyeFade ? "0.4" : "1";
    applyImmersion();
  };
  fadeToggle.append(cb, document.createTextNode(" eye-driven immersion fade (closed = scene, open = cue)"));
  host.append(fadeToggle);

  const immSlider = slider({
    label: "Immersion (manual)", min: 0, max: 1, step: 0.01, value: immersion,
    fmt: (v) => v.toFixed(2),
    onInput: (v) => { immersion = v; applyImmersion(); saveSoon(); },
  });
  host.append(immSlider);
  const hint = document.createElement("div");
  hint.className = "hint";
  hint.textContent = "1 = scene full / attention cue silent · 0 = scene silent / cue audible";
  host.append(hint);
}

function buildRoomPanel(): void {
  const host = $("roomPanelBody");
  const roomSel = document.createElement("select");
  ROOMS.forEach((r, i) => roomSel.add(new Option(r, String(i))));
  roomSel.value = String(roomIdx);
  roomSel.onchange = () => { roomIdx = +roomSel.value; engine?.setRoom(roomIdx); void syncRoomGeom(); saveSoon(); };
  host.append(roomSel);
  const dimsHint = document.createElement("div");
  dimsHint.className = "hint";
  dimsHint.id = "roomDimsHint";
  dimsHint.textContent = roomDimsText();
  host.append(dimsHint);

  const refl = document.createElement("label");
  refl.className = "toggle";
  const rcb = document.createElement("input");
  rcb.type = "checkbox";
  rcb.checked = reflections;
  rcb.onchange = () => { reflections = rcb.checked; engine?.setReflections(reflections); saveSoon(); };
  refl.append(rcb, document.createTextNode(" early reflections (image-source)"));
  host.append(refl);

  host.append(
    slider({ label: "Late tail: FDN ↔ BRIR", min: 0, max: 1, step: 0.01, value: reverbBlend, onInput: (v) => { reverbBlend = v; engine?.setReverbBlend(v); saveSoon(); } }),
    slider({ label: "Master gain", min: 0, max: 1.2, step: 0.01, value: master, onInput: (v) => { master = v; engine?.setMaster(v); saveSoon(); } }),
    slider({ label: "HRTF fit (freq scale)", min: 0.5, max: 2.2, step: 0.01, value: fit, onInput: (v) => { fit = v; engine?.setFreqScale(v); saveSoon(); } }),
  );
  const hint = document.createElement("div");
  hint.className = "hint";
  hint.textContent = "FDN↔BRIR blend only affects the (BRIR) rooms.";
  host.append(hint);

  // --- doorway experiment: a rectangular aperture marker on one wall -----------
  const dHead = document.createElement("div");
  dHead.className = "subhead";
  dHead.textContent = "Doorway";
  host.append(dHead);

  const applyDoor = () => {
    view.setDoor(door.enabled ? door : null);
    saveSoon();
  };
  const doorToggle = document.createElement("label");
  doorToggle.className = "toggle";
  const dcb = document.createElement("input");
  dcb.type = "checkbox";
  dcb.checked = door.enabled;
  dcb.onchange = () => { door.enabled = dcb.checked; applyDoor(); };
  doorToggle.append(dcb, document.createTextNode(" show doorway on wall"));
  host.append(doorToggle);

  host.append(segButtons<DoorConfig["wall"]>(["-x", "+x", "-z", "+z"], door.wall, (v) => { door.wall = v; applyDoor(); }));
  host.append(
    slider({ label: "Position along wall", min: -15, max: 15, step: 0.1, value: door.along, fmt: (v) => v.toFixed(1) + " m", onInput: (v) => { door.along = v; applyDoor(); } }),
    slider({ label: "Width", min: 0.5, max: 8, step: 0.1, value: door.width, fmt: (v) => v.toFixed(1) + " m", onInput: (v) => { door.width = v; applyDoor(); } }),
    slider({ label: "Height", min: 0.5, max: 8, step: 0.1, value: door.height, fmt: (v) => v.toFixed(1) + " m", onInput: (v) => { door.height = v; applyDoor(); } }),
  );
  const doorHint = document.createElement("div");
  doorHint.className = "hint";
  doorHint.textContent = "−z is in front of the listener. Use a source's “→ doorway” button to place it in the aperture; drag sources beyond the wall to try “outside the door”.";
  host.append(doorHint);
}

function buildAttnPanel(): void {
  const host = $("attnPanelBody");
  const row = document.createElement("div");
  row.className = "btnrow";
  const minus = document.createElement("button");
  minus.textContent = "−";
  const count = document.createElement("span");
  count.className = "count";
  const plus = document.createElement("button");
  plus.textContent = "＋";
  const paint = () => (count.textContent = `${attnAgents} waiting`);
  paint();
  minus.onclick = () => { attnAgents = Math.max(0, attnAgents - 1); engine?.setAttentionAgents(attnAgents); paint(); saveSoon(); };
  plus.onclick = () => { attnAgents = Math.min(8, attnAgents + 1); engine?.setAttentionAgents(attnAgents); paint(); saveSoon(); };
  row.append(minus, count, plus);
  host.append(row);
  host.append(
    slider({ label: "Build time", min: 0.1, max: 10, step: 0.1, value: attnBuildMin, fmt: (v) => v.toFixed(1) + " min", onInput: (v) => { attnBuildMin = v; engine?.setAttentionBuildMinutes(v); saveSoon(); } }),
  );
  const hint = document.createElement("div");
  hint.className = "hint";
  hint.textContent = "The in-engine cue rides 1 − immersion: drop immersion below 1 (or open your eyes with the fade on) to hear it.";
  host.append(hint);
}

// ---- boot ---------------------------------------------------------------------
function setStatus(t: string): void {
  $("status").textContent = t;
}

// editor tabs: Source / Listener / Room / Cue / Scene
function switchTab(name: string): void {
  document.querySelectorAll<HTMLButtonElement>("#tabbar button").forEach((b) => b.classList.toggle("on", b.dataset.tab === name));
  document.querySelectorAll(".tabpage").forEach((p) => p.classList.toggle("on", p.id === "tab-" + name));
}
document.querySelectorAll<HTMLButtonElement>("#tabbar button").forEach((b) => (b.onclick = () => switchTab(b.dataset.tab!)));

view.onSelect = (id) => {
  selected = id;
  if (id) switchTab("source");
  refreshUI();
};
view.onMove = (id, pos) => {
  const s = sources.find((x) => x.id === id);
  if (!s) return;
  s.pos = pos;
  engine?.setSource(id, { pos });
  syncView();
  if (s.id === selected) {
    const ro = document.getElementById("posReadout");
    if (ro) ro.textContent = `position: x ${pos.x.toFixed(2)}  y ${pos.y.toFixed(2)}  z ${pos.z.toFixed(2)} (drag in the 3D view)`;
    // keep the inspector's Height slider live while the up/down handle is dragged
    const hs = document.getElementById("heightSlider") as HTMLInputElement | null;
    if (hs) {
      hs.value = String(pos.y);
      const val = hs.parentElement?.querySelector(".val");
      if (val) val.textContent = pos.y.toFixed(2) + " m";
    }
  }
  saveSoon();
};
view.onAdd = (pos) => void addSource(pos);

// hover tooltip over 3D objects
const tip = document.createElement("div");
tip.id = "tooltip";
document.body.append(tip);
view.onHover = (id, x, y) => {
  const s = id ? sources.find((v) => v.id === id) : null;
  if (!s) {
    tip.style.display = "none";
    return;
  }
  const bits = [
    `<b>${s.name}</b>`,
    `x ${s.pos.x.toFixed(2)} · y ${s.pos.y.toFixed(2)} · z ${s.pos.z.toFixed(2)}`,
    `vol ${s.gain.toFixed(2)} · send ${s.send.toFixed(2)}${s.loop ? " · loop" : ""}${s.playing ? "" : " · ⏸"}`,
  ];
  if (s.directivity > 0) bits.push(`directivity ${s.directivity.toFixed(2)} @ yaw ${s.facingYaw.toFixed(0)}°`);
  if (s.extent > 0) bits.push(`extent ${s.extent.toFixed(2)} m`);
  if (s.id === selected) bits.push(`<span class="dim">drag ◆ to move up/down</span>`);
  tip.innerHTML = bits.join("<br>");
  tip.style.display = "block";
  const pad = 14;
  tip.style.left = Math.min(x + pad, innerWidth - tip.offsetWidth - 8) + "px";
  tip.style.top = Math.min(y + pad, innerHeight - tip.offsetHeight - 8) + "px";
};

($("start") as HTMLButtonElement).onclick = async () => {
  if ((await ensureStarted()) && sources.length === 0) {
    void addSource({ x: 1.6, y: 0, z: -1.2 }, "sfx:6"); // drone bed: an audible looping starter
  }
};
($("add") as HTMLButtonElement).onclick = () => void addSource({ x: 0, y: 0, z: -2 });
($("addFile") as HTMLButtonElement).onclick = async () => {
  if (await ensureStarted()) ($("file") as HTMLInputElement).click();
};
($("file") as HTMLInputElement).onchange = async (e) => {
  const f = (e.target as HTMLInputElement).files?.[0];
  if (!f || !(await ensureStarted()) || !ctx) return;
  const ab = await f.arrayBuffer();
  const ad = await ctx.decodeAudioData(ab);
  fileLib.set(f.name, ad.getChannelData(0).slice() as Float32Array);
  fillNewSound();
  void addSource({ x: 0, y: 0, z: -2 }, `file:${f.name}`);
};

($("export") as HTMLButtonElement).onclick = () => {
  const blob = new Blob([JSON.stringify(sceneToJson(), null, 2)], { type: "application/json" });
  const a = document.createElement("a");
  a.href = URL.createObjectURL(blob);
  a.download = "antiphon-scene.json";
  a.click();
  URL.revokeObjectURL(a.href);
};
($("importBtn") as HTMLButtonElement).onclick = () => ($("importFile") as HTMLInputElement).click();
($("importFile") as HTMLInputElement).onchange = async (e) => {
  const f = (e.target as HTMLInputElement).files?.[0];
  if (!f) return;
  loadScene(JSON.parse(await f.text()) as SceneFile);
  saveSoon();
};
($("clear") as HTMLButtonElement).onclick = () => {
  for (const s of sources) engine?.removeSource(s.id);
  sources.length = 0;
  selected = null;
  refreshUI();
  saveSoon();
};

function fillNewSound(): void {
  const selEl = $("newSound") as HTMLSelectElement;
  const cur = selEl.value;
  selEl.innerHTML = "";
  for (const o of soundOptions()) selEl.add(new Option(o.label, o.kind));
  selEl.value = cur && [...selEl.options].some((op) => op.value === cur) ? cur : "sfx:6"; // drone bed
}
fillNewSound();

// debug/automation hook (headless smoke tests drive the editor through this)
(window as unknown as Record<string, unknown>).__sandbox = {
  view,
  sources,
  selectedId: () => selected,
};

// restore autosaved scene (sources start once the engine starts)
try {
  const saved = localStorage.getItem(STORE_KEY);
  if (saved) loadScene(JSON.parse(saved) as SceneFile);
} catch (e) {
  console.warn("scene restore failed", e);
}

refreshGlobals();
refreshUI();

// per-frame: tracking → pose + head view + eyes
function frame(): void {
  if (tracking && tracker) {
    // camera is mirrored → negate yaw so turning right faces right; position is 6DoF
    orientDeg = Math.max(-180, Math.min(180, -tracker.yaw));
    const p = tracker.pos;
    trackedPos = { x: clampM(p.x), y: clampM(p.y), z: clampM(-p.z) }; // +z (toward cam) → front (−z)
    const yawSlider = document.getElementById("yawSlider") as HTMLInputElement | null;
    if (yawSlider) yawSlider.value = String(Math.round(orientDeg));
    applyPose();
    const eyeState = document.getElementById("eyeState");
    const meter = document.getElementById("eyeMeter") as HTMLProgressElement | null;
    if (eyeState) eyeState.textContent = tracker.eyesReady ? (tracker.eyesClosed ? "eyes: closed" : "eyes: open") : "eyes: calibrating…";
    if (meter) meter.value = tracker.eyeOpenness;
    if (eyeFade) applyImmersion();
  }
  view.setHead(headPos, orientDeg);
  requestAnimationFrame(frame);
}
frame();
