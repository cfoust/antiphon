/** An agent's lifecycle state, which determines what you hear from its bearing. */
export type AgentState = "working" | "done" | "summarizing" | "heard";

/** Spatial layouts for the ring of agents around the listener. */
export type Arrangement = "ring" | "arc" | "cluster";

/**
 * What drives the agents:
 *  - "demo": scripted, self-contained — canned ElevenLabs voices loop and finish on a
 *    timer. The standalone experience.
 *  - "live": a real Claude Code session via the bridge — agents are heard only through
 *    real narration; no canned audio is loaded at all.
 */
export type ChamberMode = "demo" | "live";

/** Procedural acoustic environments (impulse responses for the shared reverb). */
export type EnvName = "dry" | "room" | "chamber" | "hall";

/** Static definition of an agent (identity, not runtime state). */
export interface AgentDef {
  id: string;
  name: string;
  color: string;
  task: string;
}

/** Live-bridge seat metadata (mirrors TalkbackSeatMeta in the native app). */
export interface SeatMeta {
  agent: string; // session id — a new tenant on the same seat resets snooze/lines
  name: string;
  kind: string; // e.g. "claude-code"
  title: string;
  input: string;
}

/** One row of the agent-list overlay (mirrors AgentListVM in ChamberEngine.swift). */
export interface AgentRow {
  seat: number;
  name: string;
  kind: string;
  title: string;
  color: string;
  status: string;
  lastLine: string;
  lastKind: string;
  waiting: boolean; // has an unheard done-summary
  snoozed: boolean;
}

/** Runtime state + Web Audio node graph for one agent. */
export interface AgentNode {
  idx: number;
  bearing: number; // radians, 0 = front, clockwise — derived from posX/posZ
  /** World position (metres, x = right, z = back; listener origin = calibrated
   *  neutral). Dragging on the radar moves this; bearing is derived. */
  posX: number;
  posZ: number;
  posSet: boolean; // a dragged position was restored/saved — arrangement won't move it
  // node graph: all of the agent's sounds sum into `sum`, which feeds the wasm engine's
  // live-input slot `idx`. The wasm engine does HRTF + room reverb (no PannerNode).
  sum: GainNode;
  src: AudioBufferSourceNode | null; // demo: looping canned work-stream. null in live.
  gain: GainNode; // the agent's voice level — demo loop or live narration feeds in here
  hp: BiquadFilterNode; // high-pass: strips the voiced low end for a breathy whisper
  lp: BiquadFilterNode; // low-pass: tames the top end
  pingBus: GainNode; // done-state ping volume; transient oscillators ride on top
  summaryGain: GainNode; // spoken summary
  summaryBuf: AudioBuffer | null; // spoken summary; demo: canned, live: set when it arrives
  // chord identity (mirrors ChamberEngine.swift): each tool call plays the next of three
  // descending notes; the chord root is the looping "working" drone.
  toolNotes: AudioBuffer[];
  toolIdx: number;
  toolBusy: boolean; // a note is sounding — bursts collapse into one note
  droneGain: GainNode; // the always-running drone loop rides this
  gDrone: number; // shadow value for the per-tick lerp (mirrors gDrone)
  // drag audition: a pulsing blip with a hot reverb send while being moved
  pulseGain: GainNode;
  gPulse: number;
  bloomGain: GainNode; // the dwell/lock hum loop (chord root) rides this
  gBloom: number; // shadow value for the per-tick lerp (mirrors gBloom)
  crestAt: number; // wall-clock ms of the last lock — the hum leans up briefly
  lastBloomAt: number; // per-agent hum cooldown (presence reminder, not a metronome)
  bloomLive: boolean; // this dwell's hum is sounding (not cooled down)
  // runtime state
  state: AgentState;
  nextPing: number; // audio-clock time of next ping
  lastPingMs: number; // wall-clock time of last ping (for visual ripples)
  heardAt: number; // wall-clock time the summary finished (for recycling)
  /** Snoozed: still receives updates, but is invisible and silent in the world. */
  snoozed: boolean;
  /** Live mode: a bound chamberd seat. Demo mode: everyone is present. */
  present: boolean;
  /** Session gone, but its unheard done-summary keeps it in the room. */
  departed: boolean;
  /** Wall time (ms) of the last sign of life (tool call or narration event) —
   *  gates the working drone so idle-but-connected sessions don't hum forever. */
  lastActivity: number;
  // live-bridge seat metadata + the last narration line (for the agent list)
  meta: SeatMeta;
  lastLine: string;
  lastKind: string;
  // live mode: the agent's voice is a queue of real narration lines (no looping bed)
  narrQueue: AudioBuffer[]; // pending narration lines
  narrPlaying: boolean; // a narration line is currently sounding
}
