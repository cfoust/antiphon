import {
  AGENTS,
  AUTO_FINISH_MAX_MS,
  AUTO_FINISH_MIN_MS,
  DRAG_MAX_M,
  DRAG_MIN_M,
  BLOOM_COOLDOWN_MS,
  DRONE_HOLD_MS,
  DWELL_MS,
  LINGER_MS,
  PING_FREQS,
  PING_INTERVAL,
  RECYCLE_MS,
} from "../agents";
import { ARRANGE, angdiff, deg, rad, TAU } from "../math";
import type {
  AgentDef,
  AgentNode,
  AgentRow,
  Arrangement,
  AntiphonMode,
  EnvName,
  SeatMeta,
} from "../types";
import { makeBloom, makeDrone, makePulse, makeToolNote, toolNoteFreqs } from "./earcons";
import { WasmEngine, ENGINE_URLS } from "./wasmEngine";

/** Map the prototype's env names to wasm room-preset indices. `room`/`hall` use the
 *  measured-style convolution-BRIR presets (4 = room_conv, 5 = hall_conv). */
const ENV_ROOM: Record<EnvName, number> = { dry: 0, room: 4, antiphon: 3, hall: 5 };
const SOURCE_RADIUS = 1.3; // ~the first range ring — the distance that sounded best

/** localStorage key for a seat's dragged world position (native: UserDefaults seatpos.*). */
const seatPosKey = (i: number) => `antiphon-seatpos.${i}`;
function loadSeatPos(i: number): { x: number; z: number } | null {
  try {
    const p = JSON.parse(localStorage.getItem(seatPosKey(i)) || "null");
    return p && typeof p.x === "number" && typeof p.z === "number" ? p : null;
  } catch {
    return null;
  }
}

/**
 * Owns the Web Audio graph and all runtime state for the antiphon. UI modules
 * read its public fields to render and call its setters to drive it; it emits
 * `onAgents` / `onOrient` so views can refresh.
 */
export class Antiphon {
  // audio graph
  ctx!: AudioContext;
  master!: GainNode;
  agentBus!: GainNode; // all agent audio; muted until the experience begins
  wasm!: WasmEngine; // the Rust binaural engine (HRTF + room reverb), via AudioWorklet
  started = false;
  readonly nodes: Record<string, AgentNode> = {};

  // listener / mix state
  orient = 0; // radians
  headPos = { x: 0, y: 0, z: 0 }; // 6DoF head translation (metres, neutral-relative) → true parallax
  ringIntel = 0; // 0..1 — ambient murmur bed kept at its quietest
  arrangement: Arrangement = "arc"; // a semicircle across the front
  env: EnvName = "hall"; // hall (BRIR) — mirrors AntiphonEngine.swift roomIndex = 5
  lookGate = 1; // 1 = forward, 0 = looking down (everyone whispers)
  activeCount = 5;
  fit = 2.0; // HRTF "fit": warps the pinna spectral cue until a source ahead sits OUT in front
  // Full-scale master level. The eyes/immersion fade is now PER-SOURCE inside the engine (see
  // setImmersion), not a master-gain ramp, so the master stays at this level.
  readonly masterFull = 0.45; // mirrors AntiphonEngine.swift openRoom()

  // "Agent waiting" attention cue: minutes to build silent→full. Lower than native's 10 for the web
  // so the pulses are audible during a short session (tune later). `lastWaiting` de-dupes the count.
  private readonly attnBuildMin = 0.5;
  private lastWaiting = -1;

  // what drives the agents (set in start()); demo loads canned audio, live never does
  mode: AntiphonMode = "demo";

  // simulation state
  autoFinish = false;
  private nextAuto = 0;
  private lingerId: string | null = null;
  private lingerStart = 0;
  private curFacedId: string | null = null;

  // radar/list interactions (mirrors AntiphonEngine.swift dragSeat/hoveredSeat/immersionHold)
  dragSeat = -1; // seat being dragged on the radar; -1 = none
  hoveredSeat = -1; // seat hovered/tapped in the agent list; -1 = none
  private immersionHold = false; // a drag audition holds the scene fully in
  private immersionEye = 1; // last eye-driven immersion target (0..1)
  private eyesClosed = false; // detector state (false when no tracker runs)
  // eyes-closed gaze dwell → the hum crests (mirrors AntiphonEngine.swift updateTalkback)
  private dwellSeat = -1;
  private dwellStart = 0;
  private cooldownSeat = -1;

  // events for the UI layer
  onAgents: () => void = () => {};
  onOrient: (degrees: number) => void = () => {};

  constructor(readonly agents: AgentDef[] = AGENTS) {}

  // ---- geometry -----------------------------------------------------------
  /** Seats currently visible in the world (present, not snoozed; demo: first N). */
  visibleSeats(): number[] {
    const out: number[] = [];
    const limit = this.mode === "demo" ? this.activeCount : this.agents.length;
    for (let i = 0; i < limit; i++) {
      const N = this.nodes[this.agents[i].id];
      if (N && N.present && !N.snoozed) out.push(i);
    }
    return out;
  }

  facedAgent(): AgentDef | null {
    // nearest visible agent by bearing — snoozed/absent agents can't be faced
    // (mirrors AntiphonEngine.swift facedIndex())
    let best = -1,
      bd = Infinity;
    for (const i of this.visibleSeats()) {
      const N = this.nodes[this.agents[i].id];
      const d = Math.abs(angdiff(N.bearing, this.orient));
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
    this.wasm?.setInputCfg(N.idx, {
      pos: { x: N.posX, y: 0, z: N.posZ },
      gain: 1,
      // as dry as the voice, dragged or not — the direct path carries position
      send: 0.05, // mirrors AntiphonEngine.swift voiceSend
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
    // --- chord identity + drag audition (mirrors AntiphonEngine.swift setup()) ---
    // the working drone: a seamless loop of the chord root, gated by gDrone in tick()
    const pf = PING_FREQS[idx % PING_FREQS.length];
    const droneGain = ctx.createGain();
    droneGain.gain.value = 0;
    droneGain.connect(sum);
    const droneSrc = ctx.createBufferSource();
    droneSrc.buffer = makeDrone(ctx, pf);
    droneSrc.loop = true;
    droneSrc.connect(droneGain);
    // the drag audition pulse: loops forever, gPulse opens it while dragged
    const pulseGain = ctx.createGain();
    pulseGain.gain.value = 0;
    pulseGain.connect(sum);
    const pulseSrc = ctx.createBufferSource();
    pulseSrc.buffer = makePulse(ctx, pf);
    pulseSrc.loop = true;
    pulseSrc.connect(pulseGain);
    // the dwell/lock hum: one continuous loop shaped entirely by gBloom
    const bloomGain = ctx.createGain();
    bloomGain.gain.value = 0;
    bloomGain.connect(sum);
    const bloomSrc = ctx.createBufferSource();
    bloomSrc.buffer = makeBloom(ctx, pf);
    bloomSrc.loop = true;
    bloomSrc.connect(bloomGain);
    // the three descending tool-call notes (one-shots, triggered in bridgeTool)
    const toolNotes = toolNoteFreqs(pf).map((f) => makeToolNote(ctx, f));

    // Content: agents start empty in BOTH modes now. Demo is driven by the
    // scripted scenario (src/demo/scenario.ts) which enqueues one-shot narration
    // murmurs + rotating done summaries (audio/demo/*, live-narration style);
    // live is fed real lines by the bridge. The old canned audio/{id}.mp3 loops
    // remain on disk only as a fallback asset set.

    // world position: a persisted dragged spot wins; otherwise the arrangement arc
    const saved = loadSeatPos(idx);
    const posX = saved ? saved.x : Math.sin(bearing) * SOURCE_RADIUS;
    const posZ = saved ? saved.z : -Math.cos(bearing) * SOURCE_RADIUS;

    this.nodes[a.id] = {
      idx,
      bearing: Math.atan2(posX, -posZ),
      posX,
      posZ,
      posSet: !!saved,
      sum,
      src: null,
      gain,
      hp,
      lp,
      pingBus,
      summaryGain,
      summaryBuf: null,
      toolNotes,
      toolIdx: 0,
      toolBusy: false,
      droneGain,
      gDrone: 0,
      pulseGain,
      gPulse: 0,
      bloomGain,
      gBloom: 0,
      crestAt: 0,
      lastBloomAt: 0,
      bloomLive: false,
      state: "working",
      nextPing: 0,
      lastPingMs: 0,
      heardAt: 0,
      snoozed: false,
      present: true, // demo mode: everyone is present (live flips this on bind)
      departed: false,
      lastActivity: 0,
      meta: { agent: "", name: "", kind: "", title: "", input: "" },
      lastLine: "",
      lastKind: "",
      narrQueue: [],
      narrPlaying: false,
    };
    this.placeAgent(a.id);
    droneSrc.start();
    pulseSrc.start();
    bloomSrc.start();
  }

  /** Build the graph and load voices. The context starts suspended (silent) so nothing
   *  plays until resume() is called from the Start gesture. `mode` decides whether the
   *  agents are the canned demo or driven live by a Claude Code session. */
  async start(mode: AntiphonMode = "demo"): Promise<void> {
    this.mode = mode;
    const Ctor = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    // 48 kHz to match the baked HRTF asset (most browsers honor this).
    this.ctx = new Ctor({ sampleRate: 48000 });
    this.master = this.ctx.createGain();
    // close 1.3 m arc + 6 summed voices + BRIR tail is hot -> keep the master well down
    this.master.gain.value = this.masterFull;
    // agents play through agentBus (kept silent through calibration); system
    // clips connect to master directly so they're heard while the bus is muted.
    this.agentBus = this.ctx.createGain();
    this.agentBus.gain.value = 0;
    this.agentBus.connect(this.master);
    this.master.connect(this.ctx.destination);

    // the wasm binaural engine: one live input per agent, output through the agentBus
    this.wasm = await WasmEngine.create(this.ctx, {
      ...ENGINE_URLS,
      numInputs: this.agents.length,
      maxSources: this.agents.length,
    });
    this.wasm.connect(this.agentBus);
    this.wasm.setRoom(ENV_ROOM[this.env]);
    this.wasm.setFreqScale(this.fit); // apply the default "fit" before any audio plays
    this.wasm.setAttentionBuildMinutes(this.attnBuildMin); // "agent waiting" cue build time
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

  /** Begin the scripted demo experience: fade the agents in and leave all
   *  completions to the scenario driver (src/demo/scenario.ts) — no random
   *  auto-finishing. */
  startScripted(): void {
    this.agentBus.gain.setTargetAtTime(1, this.ctx.currentTime, 0.4);
    this.autoFinish = false;
  }

  // ---- onboarding fit voice ------------------------------------------------
  // The Fit step's guide voice loops from straight ahead THROUGH the binaural
  // engine (the acoustics are the demo — mirrors engine.onboardPlay(bearing: 0)
  // in the native app). It borrows the last agent's input slot (inactive during
  // onboarding), repositions it dead ahead, and opens the (otherwise silent)
  // agent bus for the duration.
  private fitSrc: AudioBufferSourceNode | null = null;

  startFitVoice(buf: AudioBuffer): void {
    this.stopFitVoice();
    const id = this.agents[this.agents.length - 1].id;
    const N = this.nodes[id];
    if (!N) return;
    this.wasm?.setInputCfg(N.idx, {
      pos: { x: 0, y: 0, z: -SOURCE_RADIUS }, // straight ahead IS the reference
      gain: 1,
      send: 0.05,
    });
    // pad with a breath of silence so the loop doesn't run on top of itself
    const pad = this.ctx.createBuffer(
      buf.numberOfChannels,
      buf.length + Math.round(this.ctx.sampleRate * 1.1),
      this.ctx.sampleRate,
    );
    for (let c = 0; c < buf.numberOfChannels; c++)
      pad.copyToChannel(buf.getChannelData(c), c);
    const s = this.ctx.createBufferSource();
    s.buffer = pad;
    s.loop = true;
    s.connect(N.sum); // direct: bypasses the whisper mix (its gain is 0 here)
    s.start();
    this.fitSrc = s;
    this.agentBus.gain.setTargetAtTime(1, this.ctx.currentTime, 0.1);
  }

  stopFitVoice(): void {
    if (!this.fitSrc) return;
    try {
      this.fitSrc.stop();
    } catch {
      /* already stopped */
    }
    this.fitSrc = null;
    // re-silence the bus (startScripted/startLive/startAuto ramp it back up)
    // and put the borrowed slot back where its agent lives.
    this.agentBus.gain.setTargetAtTime(0, this.ctx.currentTime, 0.05);
    this.placeAgent(this.agents[this.agents.length - 1].id);
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
    if (N.snoozed) return; // snoozed: no pings; the timer keeps cycling
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
    N.heardAt = 0;
    if (N.departed) {
      // summary heard and the session is long gone — leave the room
      // (mirrors AntiphonEngine.swift reset())
      N.departed = false;
      N.present = false;
    }
    const t = this.ctx.currentTime;
    N.pingBus.gain.setTargetAtTime(0, t, 0.05);
    N.summaryGain.gain.setTargetAtTime(0, t, 0.05);
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
    // exactly one agent holds the floor: the single nearest visible agent you face
    const winnerIdx = this.facedIndex();
    const winner = winnerIdx >= 0 ? this.agents[winnerIdx].id : null;
    const winnerDone = winner != null && this.nodes[winner].state === "done";
    const t = this.ctx.currentTime,
      k = 0.12;

    this.agents.forEach((a, idx) => {
      const N = this.nodes[a.id];
      if (!N) return;
      const active =
        (this.mode === "demo" ? idx < this.activeCount : N.present) && !N.snoozed;
      const faced = a.id === winner;
      const front = (Math.cos(angdiff(N.bearing, this.orient)) + 1) / 2;
      let whisper = 0,
        hpF = 900, // high-pass: high = breathy whisper, low = full voice
        lpF = 5000,
        ping = 0;
      if (active) {
        if (N.state === "working") {
          const murmur = 0.06 + this.ringIntel * 0.5; // mirrors AntiphonEngine.swift (murmur 0.06)
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
        }
        // "heard" rests silently until it recycles (static removed; mirrors AntiphonEngine.swift)
        // 'summarizing' → all stay 0; summaryGain is driven by startSummary
      }
      // reverb is now the wasm room (per-source send), so no per-agent wet/dry here
      N.gain.gain.setTargetAtTime(whisper, t, k);
      N.hp.frequency.setTargetAtTime(hpF, t, k);
      N.lp.frequency.setTargetAtTime(lpF, t, k);
      N.pingBus.gain.setTargetAtTime(ping, t, 0.08);
    });
  }

  // ---- per-frame simulation tick (called by the radar RAF) ---------------
  tick(): void {
    if (!this.started) return;
    const now = performance.now(),
      at = this.ctx.currentTime;

    // chord drone + drag audition pulse — mirrors AntiphonEngine.swift tick():
    // the drone hums while the agent is present, awake, working, and showed a
    // sign of life recently; the pulse opens for the dot being dragged.
    this.agents.forEach((a, i) => {
      const N = this.nodes[a.id];
      if (!N) return;
      const busy =
        N.present &&
        !N.snoozed &&
        N.state === "working" &&
        N.lastActivity > 0 &&
        now - N.lastActivity < DRONE_HOLD_MS;
      N.gDrone += ((busy ? 0.5 : 0) - N.gDrone) * 0.03; // slow ~1.5 s fade either way
      N.droneGain.gain.value = N.gDrone;
      N.gPulse += ((i === this.dragSeat ? 0.9 : 0) - N.gPulse) * 0.12;
      N.pulseGain.gain.value = N.gPulse;
    });

    // dwell/lock hum — mirrors AntiphonEngine.swift updateTalkback(): rest an
    // eyes-closed gaze on an agent and its chord-root hum builds in; holding
    // ~0.9 s "locks" (the hum leans up for a beat, then releases). There is no
    // talk-back panel on the web, so the lock is purely the acoustic moment;
    // the cooldown keeps a held gaze from cresting over and over.
    if (this.eyesClosed) {
      const fi = this.facedIndex();
      if (fi !== this.cooldownSeat) this.cooldownSeat = -1;
      if (fi >= 0 && fi !== this.cooldownSeat) {
        if (this.dwellSeat !== fi) {
          this.dwellSeat = fi;
          this.dwellStart = now;
          const N = this.nodes[this.agents[fi].id];
          if (N) {
            // presence reminder, at most once per cooldown per agent —
            // dwell/lock keep working silently in between
            N.bloomLive = now - N.lastBloomAt >= BLOOM_COOLDOWN_MS;
            if (N.bloomLive) N.lastBloomAt = now;
          }
        } else if (now - this.dwellStart >= DWELL_MS) {
          this.dwellSeat = -1;
          this.cooldownSeat = fi;
          const N = this.nodes[this.agents[fi].id];
          if (N && N.bloomLive) N.crestAt = now; // the crest belongs to an audible dwell
        }
      } else {
        this.dwellSeat = -1;
      }
    } else {
      this.dwellSeat = -1;
      this.cooldownSeat = -1;
    }
    this.agents.forEach((a, i) => {
      const N = this.nodes[a.id];
      if (!N) return;
      let target = i === this.dwellSeat && N.bloomLive ? 0.7 : 0;
      if (now - N.crestAt < 450) target = 1.0; // the crest: same hum, leaning in
      const rate = target > N.gBloom ? 0.05 : 0.03; // slow build, slower release
      N.gBloom += (target - N.gBloom) * rate;
      N.bloomGain.gain.value = N.gBloom;
    });

    // pings for done agents + recycle heard agents back to working; also count agents WAITING (done)
    let waiting = 0;
    for (let i = 0; i < this.agents.length; i++) {
      const N = this.nodes[this.agents[i].id];
      if (!N) continue;
      if (this.mode === "demo" && i >= this.activeCount) continue;
      if (N.state === "done" && !N.snoozed) waiting++;
      if (N.state === "done" && at >= N.nextPing) {
        this.schedulePing(this.agents[i].id, i);
        N.lastPingMs = now;
        N.nextPing = at + PING_INTERVAL;
      } else if (N.state === "heard") {
        if (N.heardAt && now - N.heardAt > RECYCLE_MS) {
          this.resetAgent(this.agents[i].id);
        }
      }
    }
    // drive the "agent waiting" cue: voices per pulse = number of done agents (audible eyes-open)
    if (waiting !== this.lastWaiting) {
      this.lastWaiting = waiting;
      this.wasm?.setAttentionAgents(waiting);
    }
    // auto-finish scheduler
    if (this.autoFinish && now >= this.nextAuto) {
      this.nextAuto =
        now + AUTO_FINISH_MIN_MS + Math.random() * (AUTO_FINISH_MAX_MS - AUTO_FINISH_MIN_MS);
      this.finishRandom();
    }
    // linger on a done agent → summary. Eyes-open must not consume one into a
    // silent scene (mirrors AntiphonEngine.swift); with no eye tracker the
    // immersion rests at 1, so mobile keeps the old behavior.
    const fa = this.facedAgent();
    const attending = fa && this.lookGate > 0.6 && this.immersionEye >= 0.5;
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

  // ---- radar drag + list interactions -------------------------------------
  /** A dot picked up on the radar: hold the antiphon audible (even with eyes
   *  open) and pulse the agent with a hot reverb send so its place is felt.
   *  // mirrors AntiphonEngine.swift dragBegan */
  dragBegan(seat: number): void {
    const a = this.agents[seat];
    if (!a || !this.nodes[a.id]) return;
    this.dragSeat = seat;
    this.immersionHold = true;
    this.pushImmersion();
  }

  /** Live position update while dragging (world metres). */
  dragMoved(seat: number, x: number, z: number): void {
    this.place(seat, x, z);
  }

  /** Drop: release the immersion hold, persist the spot. */
  dragEnded(): void {
    const seat = this.dragSeat;
    this.dragSeat = -1;
    this.immersionHold = false;
    this.pushImmersion();
    const a = this.agents[seat];
    if (!a || !this.nodes[a.id]) return;
    const N = this.nodes[a.id];
    N.posSet = true;
    try {
      localStorage.setItem(seatPosKey(seat), JSON.stringify({ x: N.posX, z: N.posZ }));
    } catch {
      /* private mode — position just won't persist */
    }
  }

  /** Clamps to a sane annulus (too close is deafening, too far is inaudible)
   *  and keeps position, bearing and the DSP source in sync.
   *  // mirrors AntiphonEngine.swift place(seat:) */
  private place(seat: number, x: number, z: number): void {
    const a = this.agents[seat];
    if (!a || !this.nodes[a.id]) return;
    const N = this.nodes[a.id];
    const d = Math.max(Math.hypot(x, z), 1e-6);
    const clamped = Math.min(Math.max(d, DRAG_MIN_M), DRAG_MAX_M);
    N.posX = (x * clamped) / d;
    N.posZ = (z * clamped) / d;
    N.bearing = Math.atan2(N.posX, -N.posZ);
    this.placeAgent(a.id);
    if (this.started) this.updateMix();
  }

  /** Snooze: the agent leaves the world (no dot, no sound) but keeps receiving
   *  updates; un-snoozing brings it back where it was.
   *  // mirrors AntiphonEngine.swift setSnoozed */
  setSnoozed(seat: number, on: boolean): void {
    const a = this.agents[seat];
    if (!a || !this.nodes[a.id]) return;
    const N = this.nodes[a.id];
    N.snoozed = on;
    if (on) {
      if (this.dragSeat === seat) this.dragEnded();
      if (this.hoveredSeat === seat) this.hoveredSeat = -1;
    } else if (N.narrQueue.length && !N.narrPlaying) {
      this.drainNarr(a.id); // resume the accumulated narration
    }
    this.onAgents();
    if (this.started) this.updateMix();
  }

  /** List hover/tap → radar highlight. */
  setHovered(seat: number): void {
    this.hoveredSeat = seat;
  }

  // ---- setters ------------------------------------------------------------
  setOrient(degrees: number): void {
    this.orient = ((((degrees % 360) + 360) % 360) * Math.PI) / 180;
    const fa = this.facedAgent();
    const faId = fa ? fa.id : null;
    if (faId !== this.curFacedId) {
      this.curFacedId = faId;
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

  /** Immersion envelope: closing your eyes makes the binaural scene immersive. `imm` is a
   *  continuous 0..1 (0 = eyes open/scene silent, 1 = eyes closed/scene full). Applied PER-SOURCE
   *  inside the engine now (not a master ramp): the renderer scales scene sources by `imm` and the
   *  attention cue by (1−imm), so opening your eyes crossfades the scene OUT and the cue IN through
   *  one shared reverb (the scene's tail rings out naturally). Smoothed in-engine (τ≈0.25 s).
   *  While a radar drag is in flight the hold pins the scene fully in regardless of eye state. */
  setImmersion(imm: number): void {
    this.immersionEye = Math.max(0, Math.min(1, imm));
    this.pushImmersion();
  }

  private pushImmersion(): void {
    this.wasm?.setImmersionEngine(this.immersionHold ? 1 : this.immersionEye);
  }

  /** Convenience over setImmersion for the boolean eyes-closed detector: closed → full,
   *  open → silent (full-silence floor; change the 0 below if a small floor reads better). */
  setEyesClosed(closed: boolean): void {
    this.eyesClosed = closed;
    this.setImmersion(closed ? 1 : 0);
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
    // live agents exist only as bound seats (mirrors applyLiveMode in the native app)
    for (const a of this.agents) {
      const N = this.nodes[a.id];
      if (N) N.present = false;
    }
    this.reArrange();
    this.onAgents();
  }

  /** Decode raw audio bytes (an MP3 line from the bridge) into a buffer. */
  decodeBytes(buf: ArrayBuffer): Promise<AudioBuffer> {
    return this.ctx.decodeAudioData(buf);
  }

  /** A session connected → light up seat `idx` and grow the arc to include it.
   *  `meta` mirrors bridgeBind in the native app: a different session id on the
   *  same seat is a new tenant — its predecessor's snooze must not silence it. */
  bindSeat(idx: number, meta?: Partial<SeatMeta>): void {
    const a = this.agents[idx];
    if (!a) return;
    const N = this.nodes[a.id];
    if (!N) return;
    let newTenant = false;
    if (meta) {
      if (meta.agent) {
        newTenant = N.meta.agent !== "" && N.meta.agent !== meta.agent;
        N.meta.agent = meta.agent;
      }
      if (meta.name) N.meta.name = meta.name;
      if (meta.kind) N.meta.kind = meta.kind;
      if (meta.title) N.meta.title = meta.title;
      N.meta.input = meta.input ?? "";
    }
    if (newTenant) {
      N.lastLine = "";
      N.lastKind = "";
      N.snoozed = false;
    }
    N.present = true;
    N.departed = false;
    N.state = "working";
    if (idx + 1 > this.activeCount) this.activeCount = idx + 1;
    this.reArrange();
    this.onAgents();
    if (this.started) this.updateMix();
  }

  /** A session disconnected. If its unheard done-summary is still pending, the
   *  agent stays in the room (pinging) until it's heard — that's the whole point
   *  of the antiphon. Otherwise it leaves. // mirrors AntiphonEngine.swift bridgeFree */
  unbindSeat(idx: number): void {
    const a = this.agents[idx];
    if (!a) return;
    const N = this.nodes[a.id];
    if (!N) return;
    N.narrQueue.length = 0;
    N.meta.input = "";
    if (N.state === "done" || N.state === "summarizing") {
      N.departed = true;
      this.onAgents();
    } else {
      N.present = false;
      this.resetAgent(a.id);
    }
  }

  /** Update a seat's task label (cosmetic; the headline is also spoken via a clip). */
  setTask(idx: number, text: string): void {
    const a = this.agents[idx];
    if (!a) return;
    a.task = text;
    this.onAgents();
  }

  /** Narration text (task/progress/blocked/done) → the list's last-line + the
   *  drone's sign-of-life clock. // mirrors AntiphonEngine.swift bridgeLine */
  bridgeLine(idx: number, kind: string, text: string): void {
    const a = this.agents[idx];
    if (!a) return;
    const N = this.nodes[a.id];
    if (!N) return;
    N.lastLine = text;
    N.lastKind = kind;
    N.lastActivity = performance.now();
    this.onAgents();
  }

  /** A tool call from the live bridge: play the next descending chord note.
   *  Triggered only while idle, so a burst of calls collapses into one note.
   *  // mirrors AntiphonEngine.swift bridgeTool */
  bridgeTool(idx: number): void {
    const a = this.agents[idx];
    if (!a) return;
    const N = this.nodes[a.id];
    if (!N) return;
    N.lastActivity = performance.now();
    if (!N.present || N.snoozed || N.toolBusy || !N.toolNotes.length) return;
    N.toolBusy = true;
    const s = this.ctx.createBufferSource();
    s.buffer = N.toolNotes[N.toolIdx];
    N.toolIdx = (N.toolIdx + 1) % N.toolNotes.length;
    s.connect(N.sum); // gain baked into the note (0.16)
    s.onended = () => {
      N.toolBusy = false;
    };
    s.start();
  }

  /** Queue a live narration line for seat `idx`; it rides the faced/whisper mix.
   *  Presence is asserted but the state machine is left alone — a stray progress
   *  line must not cancel an in-flight done. // mirrors bridgeNarration */
  enqueueProgress(idx: number, buf: AudioBuffer): void {
    const a = this.agents[idx];
    if (!a) return;
    const N = this.nodes[a.id];
    if (!N) return;
    N.present = true;
    N.narrQueue.push(buf);
    // drop-stale: never let more than (playing + 1) pile up — you hear what it's doing now
    if (N.narrQueue.length > 2) N.narrQueue.splice(0, N.narrQueue.length - 2);
    if (!N.narrPlaying && !N.snoozed) this.drainNarr(a.id);
  }

  private drainNarr(id: string): void {
    const N = this.nodes[id];
    if (!N) return;
    if (N.snoozed) {
      // snoozed: hold the queue (it keeps accumulating with drop-stale); un-snooze resumes
      N.narrPlaying = false;
      return;
    }
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

  /** Seat `idx` finished its task → run the done → ping → summary flow. A fresh
   *  done may also land on a `heard` agent (it finished another task) — only an
   *  in-flight done/summarizing keeps its current run. // mirrors applyDone */
  markDone(idx: number): void {
    const a = this.agents[idx];
    if (!a) return;
    const N = this.nodes[a.id];
    if (!N) return;
    N.present = true;
    if (N.state === "heard") {
      N.state = "working";
      N.heardAt = 0;
    }
    this.setDone(a.id);
  }

  private reArrange(): void {
    if (!this.started) return;
    const bs = ARRANGE[this.arrangement](this.activeCount);
    this.agents.forEach((a, i) => {
      const N = this.nodes[a.id];
      if (!N) return;
      // a dragged/persisted position is the user's word — the arrangement won't move it
      if (i < this.activeCount && !N.posSet) {
        N.posX = Math.sin(bs[i]) * SOURCE_RADIUS;
        N.posZ = -Math.cos(bs[i]) * SOURCE_RADIUS;
        N.bearing = Math.atan2(N.posX, -N.posZ);
      }
      this.placeAgent(a.id);
    });
    this.updateMix();
  }

  // ---- the agent list ------------------------------------------------------
  /** Rows for everyone in the room, snoozed included.
   *  // mirrors AntiphonEngine.swift buildAgentList */
  buildAgentList(): AgentRow[] {
    const now = performance.now();
    const live = this.mode === "live";
    const rows: AgentRow[] = [];
    this.agents.forEach((a, i) => {
      const N = this.nodes[a.id];
      if (!N) return;
      if (live ? !N.present : i >= this.activeCount) return;
      let status: string;
      switch (N.state) {
        case "done":
          status = N.departed ? "finished — summary waiting" : "finished — waiting to report";
          break;
        case "summarizing":
          status = "reporting";
          break;
        case "heard":
          status = "resting";
          break;
        default:
          status = !live
            ? "working"
            : N.lastActivity > 0 && now - N.lastActivity < DRONE_HOLD_MS
              ? "working"
              : "idle";
      }
      rows.push({
        seat: i,
        name: N.meta.name || a.name,
        kind: N.meta.kind || (live ? "" : "demo"),
        title: N.meta.title || (live ? "" : a.task),
        color: a.color,
        status,
        lastLine: N.lastLine,
        lastKind: N.lastKind,
        waiting: N.state === "done",
        snoozed: N.snoozed,
      });
    });
    return rows;
  }
}
