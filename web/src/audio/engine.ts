import {
  AGENTS,
  AUTO_FINISH_MAX_MS,
  AUTO_FINISH_MIN_MS,
  LINGER_MS,
  PING_FREQS,
  PING_INTERVAL,
  RECYCLE_MS,
} from "../agents";
import { ARRANGE, angdiff, deg, rad, TAU } from "../math";
import type { AgentDef, AgentNode, Arrangement, ChamberMode, EnvName } from "../types";
import { makeNoise } from "./impulse";
import { WasmEngine, ENGINE_URLS } from "./wasmEngine";

/** Map the prototype's env names to wasm room-preset indices. `room`/`hall` use the
 *  measured-style convolution-BRIR presets (4 = room_conv, 5 = hall_conv). */
const ENV_ROOM: Record<EnvName, number> = { dry: 0, room: 4, chamber: 3, hall: 5 };
const SOURCE_RADIUS = 1.3; // ~the first range ring — the distance that sounded best

/**
 * Owns the Web Audio graph and all runtime state for the chamber. UI modules
 * read its public fields to render and call its setters to drive it; it emits
 * `onAgents` / `onOrient` so views can refresh.
 */
export class Chamber {
  // audio graph
  ctx!: AudioContext;
  master!: GainNode;
  agentBus!: GainNode; // all agent audio; muted until the experience begins
  wasm!: WasmEngine; // the Rust binaural engine (HRTF + room reverb), via AudioWorklet
  noiseBuf!: AudioBuffer;
  started = false;
  readonly nodes: Record<string, AgentNode> = {};

  // listener / mix state
  orient = 0; // radians
  headPos = { x: 0, y: 0, z: 0 }; // 6DoF head translation (metres, neutral-relative) → true parallax
  ringIntel = 0; // 0..1 — ambient murmur bed kept at its quietest
  arrangement: Arrangement = "arc"; // a semicircle across the front
  env: EnvName = "room"; // measured-BRIR convolution room (the default that sounded best)
  lookGate = 1; // 1 = forward, 0 = looking down (everyone whispers)
  activeCount = 5;
  fit = 2.0; // HRTF "fit": warps the pinna spectral cue until a source ahead sits OUT in front

  // what drives the agents (set in start()); demo loads canned audio, live never does
  mode: ChamberMode = "demo";

  // simulation state
  autoFinish = false;
  private nextAuto = 0;
  private lingerId: string | null = null;
  private lingerStart = 0;
  private curFacedId: string | null = null;

  // events for the UI layer
  onAgents: () => void = () => {};
  onOrient: (degrees: number) => void = () => {};

  constructor(readonly agents: AgentDef[] = AGENTS) {}

  // ---- geometry -----------------------------------------------------------
  bearings(): number[] {
    return ARRANGE[this.arrangement](this.activeCount);
  }

  facedAgent(): AgentDef | null {
    const bs = this.bearings();
    let best = -1,
      bd = Infinity;
    for (let i = 0; i < this.activeCount; i++) {
      const d = Math.abs(angdiff(bs[i], this.orient));
      if (d < bd) {
        bd = d;
        best = i;
      }
    }
    return best >= 0 && bd < rad(40) ? this.agents[best] : null;
  }

  /** Index of the agent you're currently facing, or -1 (used to aim live input). */
  facedIndex(): number {
    const fa = this.facedAgent();
    return fa ? this.agents.indexOf(fa) : -1;
  }

  private setListener(): void {
    // forward = (sinθ, 0, −cosθ) about +y, plus 6DoF head translation so leaning gives true parallax
    this.wasm?.setPose(this.orient, this.headPos);
  }

  private placeAgent(id: string): void {
    const N = this.nodes[id];
    const R = SOURCE_RADIUS;
    this.wasm?.setInputCfg(N.idx, {
      pos: { x: Math.sin(N.bearing) * R, y: 0, z: -Math.cos(N.bearing) * R },
      gain: 1,
      send: 0.3,
    });
  }

  // ---- loading ------------------------------------------------------------
  private async decode(url: string): Promise<AudioBuffer> {
    const r = await fetch(url);
    return this.ctx.decodeAudioData(await r.arrayBuffer());
  }

  private async loadAgent(a: AgentDef, idx: number, bearing: number): Promise<void> {
    const ctx = this.ctx;

    // --- per-agent pre-spatial sum -> wasm engine input slot `idx` (HRTF + reverb there) ---
    const sum = ctx.createGain();
    this.wasm.connectInput(sum, idx);

    // the agent's voice path: whatever sounds (demo's loop or live's narration lines)
    // feeds `gain`, which the mix opens from breathy whisper to clear voice as you turn.
    const gain = ctx.createGain();
    gain.gain.value = 0;
    const hp = ctx.createBiquadFilter();
    hp.type = "highpass"; // high = breathy whisper, low = full voice
    hp.frequency.value = 900;
    const lp = ctx.createBiquadFilter();
    lp.type = "lowpass";
    lp.frequency.value = 5000;
    gain.connect(hp).connect(lp).connect(sum);

    // ping bus (volume per-frame; oscillators ride on top) -> sum
    const pingBus = ctx.createGain();
    pingBus.gain.value = 0;
    pingBus.connect(sum);
    // spoken summary -> sum
    const summaryGain = ctx.createGain();
    summaryGain.gain.value = 0;
    summaryGain.connect(sum);
    // radio static (heard, when faced): noise -> tight bandpass -> gate -> drift -> panner
    // A narrow band reads as a weak tuned signal rather than broadband hiss;
    // the drift gain flutters in tick() so you only catch fragments of it.
    const stSrc = ctx.createBufferSource();
    stSrc.buffer = this.noiseBuf;
    stSrc.loop = true;
    const stBP = ctx.createBiquadFilter();
    stBP.type = "bandpass";
    stBP.frequency.value = 1400;
    stBP.Q.value = 3.5;
    const stGain = ctx.createGain();
    stGain.gain.value = 0;
    const stMod = ctx.createGain();
    stMod.gain.value = 0;
    stSrc.connect(stBP).connect(stGain).connect(stMod).connect(sum);

    // --- content: demo loads the canned (fake) voices; live stays empty until the
    // bridge feeds it real narration + summary. ---
    let src: AudioBufferSourceNode | null = null;
    let summaryBuf: AudioBuffer | null = null;
    if (this.mode === "demo") {
      const [workBuf, doneBuf] = await Promise.all([
        this.decode(`audio/${a.id}.mp3`),
        this.decode(`audio/${a.id}_done.mp3`),
      ]);
      summaryBuf = doneBuf;
      src = ctx.createBufferSource();
      src.buffer = workBuf;
      src.loop = true;
      src.connect(gain); // the looping work-stream feeds the voice path
    }

    this.nodes[a.id] = {
      idx,
      bearing,
      sum,
      src,
      gain,
      hp,
      lp,
      pingBus,
      summaryGain,
      stGain,
      stMod,
      stNextMod: 0,
      summaryBuf,
      state: "working",
      nextPing: 0,
      lastPingMs: 0,
      focusFlash: 0,
      heardAt: 0,
      narrQueue: [],
      narrPlaying: false,
    };
    this.placeAgent(a.id);
    if (src) src.start(0, Math.random() * src.buffer!.duration);
    stSrc.start();
  }

  /** Build the graph and load voices. The context starts suspended (silent) so nothing
   *  plays until resume() is called from the Start gesture. `mode` decides whether the
   *  agents are the canned demo or driven live by a Claude Code session. */
  async start(mode: ChamberMode = "demo"): Promise<void> {
    this.mode = mode;
    const Ctor = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    // 48 kHz to match the baked HRTF asset (most browsers honor this).
    this.ctx = new Ctor({ sampleRate: 48000 });
    this.master = this.ctx.createGain();
    // close 1.3 m arc + 6 summed voices + BRIR tail is hot -> keep the master well down
    this.master.gain.value = 0.42;
    // agents play through agentBus (kept silent through calibration); system
    // clips connect to master directly so they're heard while the bus is muted.
    this.agentBus = this.ctx.createGain();
    this.agentBus.gain.value = 0;
    this.agentBus.connect(this.master);
    this.master.connect(this.ctx.destination);
    this.noiseBuf = makeNoise(this.ctx, 2.0);

    // the wasm binaural engine: one live input per agent, output through the agentBus
    this.wasm = await WasmEngine.create(this.ctx, {
      ...ENGINE_URLS,
      numInputs: this.agents.length,
      maxSources: this.agents.length,
    });
    this.wasm.connect(this.agentBus);
    this.wasm.setRoom(ENV_ROOM[this.env]);
    this.wasm.setFreqScale(this.fit); // apply the default "fit" before any audio plays
    this.setListener();

    const bs = ARRANGE[this.arrangement](this.activeCount);
    await Promise.all(
      this.agents.map((a, i) =>
        this.loadAgent(a, i, bs[i] ?? (i / this.agents.length) * TAU),
      ),
    );
    this.started = true;
    this.updateMix();
    await this.ctx.suspend();
  }

  /** Unmute (from the Start user gesture). Calibration runs while this is live
   *  but before auto-finishing begins. */
  async resume(): Promise<void> {
    await this.ctx.resume();
  }

  /** Begin the experience after calibration: fade the agents in and start
   *  them finishing on their own. */
  startAuto(): void {
    this.agentBus.gain.setTargetAtTime(1, this.ctx.currentTime, 0.4);
    this.autoFinish = true;
    this.nextAuto = performance.now() + 5000; // first finish a few seconds in
  }

  /** Decode a one-shot system clip (e.g. calibration prompts). */
  loadClip(url: string): Promise<AudioBuffer> {
    return this.decode(url);
  }

  /** Play a clip centered (non-spatial) through the master bus; resolves on end
   *  (with a duration-based fallback so it can never hang the calibration flow). */
  playClip(buf: AudioBuffer): Promise<void> {
    return new Promise((res) => {
      const s = this.ctx.createBufferSource();
      s.buffer = buf;
      s.connect(this.master);
      let done = false;
      const finish = () => {
        if (!done) {
          done = true;
          res();
        }
      };
      s.onended = finish;
      s.start();
      setTimeout(finish, buf.duration * 1000 + 400);
    });
  }

  // ---- earcons ------------------------------------------------------------
  private schedulePing(id: string, idx: number): void {
    const N = this.nodes[id];
    const at = this.ctx.currentTime;
    const f = PING_FREQS[idx % PING_FREQS.length];
    for (const [mult, amp] of [
      [1, 0.5],
      [1.5, 0.22],
    ] as const) {
      const o = this.ctx.createOscillator();
      o.type = "sine";
      o.frequency.value = f * mult;
      const e = this.ctx.createGain();
      e.gain.setValueAtTime(0.0001, at);
      e.gain.linearRampToValueAtTime(amp, at + 0.012);
      e.gain.exponentialRampToValueAtTime(0.0006, at + 0.55);
      o.connect(e).connect(N.pingBus); // rides the (ducked) ping bus
      o.start(at);
      o.stop(at + 0.6);
    }
  }

  private playConfirm(id: string): void {
    const N = this.nodes[id];
    const at = this.ctx.currentTime;
    for (const [f, dt] of [
      [587.33, 0],
      [880.0, 0.1],
    ] as const) {
      const o = this.ctx.createOscillator();
      o.type = "triangle";
      o.frequency.value = f;
      const e = this.ctx.createGain();
      e.gain.setValueAtTime(0.0001, at + dt);
      e.gain.linearRampToValueAtTime(0.34, at + dt + 0.02);
      e.gain.exponentialRampToValueAtTime(0.0006, at + dt + 0.24);
      o.connect(e).connect(N.sum); // direct to the agent sum: always clear (faced-only)
      o.start(at + dt);
      o.stop(at + dt + 0.3);
    }
  }

  // ---- state transitions --------------------------------------------------
  setDone(id: string): void {
    const N = this.nodes[id];
    if (!N || N.state !== "working") return;
    N.state = "done";
    N.nextPing = this.ctx.currentTime + 0.15 + Math.random() * 0.6;
    N.lastPingMs = 0;
    this.onAgents();
    if (this.started) this.updateMix();
  }

  private startSummary(id: string): void {
    const N = this.nodes[id];
    if (!N || N.state !== "done") return;
    const summary = N.summaryBuf;
    if (!summary) {
      // No summary audio (a live agent that finished without one) — acknowledge quietly
      // and move on. There is no canned fallback to fall back to.
      N.state = "heard";
      N.heardAt = performance.now();
      this.lingerId = null;
      this.onAgents();
      this.updateMix();
      return;
    }
    N.state = "summarizing";
    this.lingerId = null;
    this.onAgents();
    this.updateMix();
    this.playConfirm(id);
    setTimeout(() => {
      if (N.state !== "summarizing") return;
      const s = this.ctx.createBufferSource();
      s.buffer = summary;
      N.summaryGain.gain.setTargetAtTime(0.95, this.ctx.currentTime, 0.05);
      s.connect(N.summaryGain);
      s.onended = () => {
        N.summaryGain.gain.setTargetAtTime(0, this.ctx.currentTime, 0.1);
        N.state = "heard";
        N.heardAt = performance.now();
        this.onAgents();
        if (this.started) this.updateMix();
      };
      s.start();
    }, 650);
  }

  resetAgent(id: string): void {
    const N = this.nodes[id];
    if (!N) return;
    N.state = "working";
    const t = this.ctx.currentTime;
    N.pingBus.gain.setTargetAtTime(0, t, 0.05);
    N.summaryGain.gain.setTargetAtTime(0, t, 0.05);
    N.stGain.gain.setTargetAtTime(0, t, 0.05);
    N.stMod.gain.setTargetAtTime(0, t, 0.05);
    this.onAgents();
    if (this.started) this.updateMix();
  }

  finishRandom(): void {
    const cand = this.agents
      .slice(0, this.activeCount)
      .filter((a) => this.nodes[a.id]?.state === "working");
    if (cand.length) this.setDone(cand[(Math.random() * cand.length) | 0].id);
  }

  resetAll(): void {
    for (const a of this.agents) if (this.nodes[a.id]) this.resetAgent(a.id);
  }

  // ---- the mix ------------------------------------------------------------
  updateMix(): void {
    if (!this.started) return;
    // exactly one agent holds the floor: the single nearest active agent you face
    let winner: string | null = null,
      wd = Infinity;
    for (let i = 0; i < this.activeCount; i++) {
      const N = this.nodes[this.agents[i].id];
      if (!N) continue;
      const d = Math.abs(angdiff(N.bearing, this.orient));
      if (d < wd) {
        wd = d;
        winner = this.agents[i].id;
      }
    }
    if (wd > rad(40)) winner = null;
    const winnerDone = winner != null && this.nodes[winner].state === "done";
    const t = this.ctx.currentTime,
      k = 0.12;

    this.agents.forEach((a, idx) => {
      const N = this.nodes[a.id];
      if (!N) return;
      const active = idx < this.activeCount;
      const faced = a.id === winner;
      const front = (Math.cos(angdiff(N.bearing, this.orient)) + 1) / 2;
      let whisper = 0,
        hpF = 900, // high-pass: high = breathy whisper, low = full voice
        lpF = 5000,
        ping = 0,
        stat = 0;
      if (active) {
        if (N.state === "working") {
          const murmur = 0.05 + this.ringIntel * 0.5;
          const g = this.lookGate; // 1 = facing forward, 0 = looking down
          if (faced) {
            // turn toward it → opens from whisper into clear voice; look down → whisper again
            whisper = murmur + (1 - murmur) * g;
            hpF = 900 + (90 - 900) * g;
            lpF = 5000 + (16000 - 5000) * g;
          } else {
            // the ambient bed: breathy, high-passed, pitch-weak — an actual whisper
            const bias = 0.82 + 0.18 * front;
            whisper = murmur * bias;
            hpF = 900;
            lpF = 5000;
          }
        } else if (N.state === "done") {
          ping = (faced ? 0.9 : winnerDone ? 0.12 : 0.4) * (0.5 + 0.5 * this.lookGate);
        } else if (N.state === "heard") {
          stat = faced ? 0.1 * this.lookGate : 0; // faint static only when you look at it
        }
        // 'summarizing' → all stay 0; summaryGain is driven by startSummary
      }
      // reverb is now the wasm room (per-source send), so no per-agent wet/dry here
      N.gain.gain.setTargetAtTime(whisper, t, k);
      N.hp.frequency.setTargetAtTime(hpF, t, k);
      N.lp.frequency.setTargetAtTime(lpF, t, k);
      N.pingBus.gain.setTargetAtTime(ping, t, 0.08);
      N.stGain.gain.setTargetAtTime(stat, t, 0.15);
    });
  }

  // ---- per-frame simulation tick (called by the radar RAF) ---------------
  tick(): void {
    if (!this.started) return;
    const now = performance.now(),
      at = this.ctx.currentTime;
    // pings for done agents + recycle heard agents back to working
    for (let i = 0; i < this.activeCount; i++) {
      const N = this.nodes[this.agents[i].id];
      if (!N) continue;
      if (N.state === "done" && at >= N.nextPing) {
        this.schedulePing(this.agents[i].id, i);
        N.lastPingMs = now;
        N.nextPing = at + PING_INTERVAL;
      } else if (N.state === "heard") {
        if (N.heardAt && now - N.heardAt > RECYCLE_MS) {
          this.resetAgent(this.agents[i].id);
        } else if (now >= N.stNextMod) {
          // drift the static in/out so we only catch fragments — sometimes it drops out
          N.stNextMod = now + 120 + Math.random() * 380;
          const target = Math.random() < 0.45 ? 0 : 0.25 + Math.random() * 0.75;
          N.stMod.gain.setTargetAtTime(target, at, 0.05);
        }
      }
    }
    // auto-finish scheduler
    if (this.autoFinish && now >= this.nextAuto) {
      this.nextAuto =
        now + AUTO_FINISH_MIN_MS + Math.random() * (AUTO_FINISH_MAX_MS - AUTO_FINISH_MIN_MS);
      this.finishRandom();
    }
    // linger on a done agent → summary
    const fa = this.facedAgent();
    const attending = fa && this.lookGate > 0.6;
    if (attending && this.nodes[fa.id]?.state === "done") {
      if (this.lingerId !== fa.id) {
        this.lingerId = fa.id;
        this.lingerStart = now;
      } else if (now - this.lingerStart >= LINGER_MS) {
        this.startSummary(fa.id);
      }
    } else {
      this.lingerId = null;
    }
  }

  // ---- setters ------------------------------------------------------------
  setOrient(degrees: number): void {
    this.orient = ((((degrees % 360) + 360) % 360) * Math.PI) / 180;
    const fa = this.facedAgent();
    const faId = fa ? fa.id : null;
    if (faId !== this.curFacedId) {
      this.curFacedId = faId;
      if (faId && this.nodes[faId]) this.nodes[faId].focusFlash = performance.now();
      this.onAgents();
    }
    if (this.started) {
      this.setListener();
      this.updateMix();
    }
    this.onOrient(deg(this.orient));
  }

  /** 6DoF head translation, world metres, neutral-relative (+x right, +y up, front −z). */
  setPosition(p: { x: number; y: number; z: number }): void {
    this.headPos = p;
    if (this.started) this.setListener();
  }

  getOrient(): number {
    return deg(this.orient);
  }

  setRingIntel(v: number): void {
    this.ringIntel = v;
    if (this.started) this.updateMix();
  }

  setLookGate(v: number): void {
    this.lookGate = Math.max(0, Math.min(1, v));
    if (this.started) this.updateMix();
  }

  setMasterVol(v: number): void {
    if (this.master) this.master.gain.value = v;
  }

  /** HRTF "fit": dial until a source straight ahead sits OUT in front at ear level. */
  setFit(v: number): void {
    this.fit = v;
    this.wasm?.setFreqScale(v);
  }

  getFit(): number {
    return this.fit;
  }

  setArrangement(a: Arrangement): void {
    this.arrangement = a;
    this.reArrange();
    this.setOrient(deg(this.orient));
  }

  setEnv(name: EnvName): void {
    this.env = name;
    this.wasm?.setRoom(ENV_ROOM[name]);
    if (this.started) this.updateMix();
  }

  setActiveCount(n: number): void {
    this.activeCount = Math.max(1, Math.min(this.agents.length, n));
    this.reArrange();
    this.onAgents();
    this.setOrient(deg(this.orient));
  }

  setAutoFinish(on: boolean): void {
    this.autoFinish = on;
    this.nextAuto = performance.now() + 800;
  }

  // ---- live mode (driven by a real Claude Code session via the bridge) ----
  /** Begin the live experience after calibration. There's no canned audio to manage —
   *  start() built the agents empty; they're heard only via real narration. */
  startLive(): void {
    this.autoFinish = false;
    // cluster the agents toward the front of view (a tight ±32° fan) rather than the
    // full −90°…+90° demo arc, so even one or two sit ahead of you, not hard left/right.
    this.arrangement = "cluster";
    this.agentBus.gain.setTargetAtTime(1, this.ctx.currentTime, 0.4);
    this.activeCount = 1; // grows as sessions bind
    this.reArrange();
    this.onAgents();
  }

  /** Decode raw audio bytes (an MP3 line from the bridge) into a buffer. */
  decodeBytes(buf: ArrayBuffer): Promise<AudioBuffer> {
    return this.ctx.decodeAudioData(buf);
  }

  /** A session connected → light up seat `idx` and grow the arc to include it. */
  bindSeat(idx: number, label?: string): void {
    const a = this.agents[idx];
    if (!a) return;
    const N = this.nodes[a.id];
    if (!N) return;
    N.state = "working";
    if (label) a.task = label;
    if (idx + 1 > this.activeCount) this.activeCount = idx + 1;
    this.reArrange();
    this.onAgents();
    if (this.started) this.updateMix();
  }

  /** A session disconnected → clear and reset its seat. */
  unbindSeat(idx: number): void {
    const a = this.agents[idx];
    if (!a) return;
    const N = this.nodes[a.id];
    if (!N) return;
    N.narrQueue.length = 0;
    this.resetAgent(a.id);
  }

  /** Update a seat's task label (cosmetic; the headline is also spoken via a clip). */
  setTask(idx: number, text: string): void {
    const a = this.agents[idx];
    if (!a) return;
    a.task = text;
    this.onAgents();
  }

  /** Queue a live narration line for seat `idx`; it rides the faced/whisper mix. */
  enqueueProgress(idx: number, buf: AudioBuffer): void {
    const a = this.agents[idx];
    if (!a) return;
    const N = this.nodes[a.id];
    if (!N) return;
    if (N.state !== "working") {
      N.state = "working";
      this.onAgents();
      if (this.started) this.updateMix();
    }
    N.narrQueue.push(buf);
    // drop-stale: never let more than (playing + 1) pile up — you hear what it's doing now
    if (N.narrQueue.length > 2) N.narrQueue.splice(0, N.narrQueue.length - 2);
    if (!N.narrPlaying) this.drainNarr(a.id);
  }

  private drainNarr(id: string): void {
    const N = this.nodes[id];
    if (!N) return;
    const buf = N.narrQueue.shift();
    if (!buf) {
      N.narrPlaying = false;
      return;
    }
    N.narrPlaying = true;
    const s = this.ctx.createBufferSource();
    s.buffer = buf;
    s.connect(N.gain);
    s.onended = () => this.drainNarr(id);
    s.start();
  }

  /** Set the (bridge-synthesized) summary audio before marking the seat done. */
  setSummaryClip(idx: number, buf: AudioBuffer): void {
    const a = this.agents[idx];
    if (!a) return;
    const N = this.nodes[a.id];
    if (N) N.summaryBuf = buf;
  }

  /** Seat `idx` finished its task → run the done → ping → summary flow. */
  markDone(idx: number): void {
    const a = this.agents[idx];
    if (a) this.setDone(a.id);
  }

  private reArrange(): void {
    if (!this.started) return;
    const bs = ARRANGE[this.arrangement](this.activeCount);
    this.agents.forEach((a, i) => {
      const N = this.nodes[a.id];
      if (!N) return;
      if (i < this.activeCount) N.bearing = bs[i];
      this.placeAgent(a.id);
    });
    this.updateMix();
  }
}
