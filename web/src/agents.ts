import type { AgentDef } from "./types";

/**
 * The agent roster. Order matters: the active-agents slider keeps the first N,
 * so Echo (the Blade Runner baseline-test reciter) sits within the default 4.
 * Audio files live in public/audio/<id>.mp3 (work stream) and <id>_done.mp3 (summary).
 */
export const AGENTS: AgentDef[] = [
  { id: "atlas", name: "Atlas", color: "#7aa2ff", task: "refactoring auth" },
  { id: "echo", name: "Echo", color: "#9aa6b8", task: "baseline test" }, // Blade Runner recitation
  { id: "wren", name: "Wren", color: "#5fd0c5", task: "db migration" },
  { id: "cass", name: "Cass", color: "#ffce6b", task: "profiling render" },
  { id: "iris", name: "Iris", color: "#c08bff", task: "chasing a flake" },
  { id: "rook", name: "Rook", color: "#ff9d7a", task: "websocket reconnect" },
];

/** Per-agent ping note — identity via pitch, a pentatonic-ish spread. */
export const PING_FREQS = [523.25, 392.0, 587.33, 659.25, 783.99, 880.0];

/** Seconds between pings for a done agent. */
export const PING_INTERVAL = 2.6;

/** Face a done agent this long (ms) to trigger its summary. */
export const LINGER_MS = 1500;

/** After a summary is heard, recycle the agent back to working after this long,
 *  so the standalone experience stays perpetually alive. */
export const RECYCLE_MS = 45000;

/** Random gap between an agent finishing on its own (relaxed cadence). */
export const AUTO_FINISH_MIN_MS = 27000;
export const AUTO_FINISH_MAX_MS = 66000;

/** How long after the last sign of life (tool call / narration) "working" keeps
 *  humming its drone before reading as idle. // mirrors ChamberEngine.swift droneHoldSecs */
export const DRONE_HOLD_MS = 45000;
// eyes-closed gaze dwell before the hum crests (mirrors ChamberEngine.swift dwellSecs)
export const DWELL_MS = 900;
// a given agent's dwell hum sounds at most this often (presence reminder)
export const BLOOM_COOLDOWN_MS = 30000;

/** Draggable-agent distance clamp: too close is deafening, too far is inaudible.
 *  // mirrors ChamberEngine.swift place(seat:) */
export const DRAG_MIN_M = 0.45;
export const DRAG_MAX_M = 2.6;
