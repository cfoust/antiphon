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

/** Runtime state + Web Audio node graph for one agent. */
export interface AgentNode {
  idx: number;
  bearing: number; // radians, 0 = front, clockwise
  // node graph: all of the agent's sounds sum into `sum`, which feeds the wasm engine's
  // live-input slot `idx`. The wasm engine does HRTF + room reverb (no PannerNode).
  sum: GainNode;
  src: AudioBufferSourceNode | null; // demo: looping canned work-stream. null in live.
  gain: GainNode; // the agent's voice level — demo loop or live narration feeds in here
  hp: BiquadFilterNode; // high-pass: strips the voiced low end for a breathy whisper
  lp: BiquadFilterNode; // low-pass: tames the top end
  pingBus: GainNode; // done-state ping volume; transient oscillators ride on top
  summaryGain: GainNode; // spoken summary
  stGain: GainNode; // radio static (heard state) — faced gating
  stMod: GainNode; // static intermittency (drifting "bits and pieces")
  stNextMod: number; // wall-clock time to pick the next static modulation target
  summaryBuf: AudioBuffer | null; // spoken summary; demo: canned, live: set when it arrives
  // runtime state
  state: AgentState;
  nextPing: number; // audio-clock time of next ping
  lastPingMs: number; // wall-clock time of last ping (for visual ripples)
  focusFlash: number; // wall-clock time you last entered this agent's focus
  heardAt: number; // wall-clock time the summary finished (for recycling)
  // live mode: the agent's voice is a queue of real narration lines (no looping bed)
  narrQueue: AudioBuffer[]; // pending narration lines
  narrPlaying: boolean; // a narration line is currently sounding
}
