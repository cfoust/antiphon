// Arpeggio-bloom synth — the "agent waiting" cue prototype, ported from arp-lab.html
// (itself a JS port of tools/sound_concepts.py pulse_note). Renders one seamless loop
// buffer from a parameter set; the sandbox feeds it to the engine as a regular source,
// so it can be placed/aimed/inflated in 3D like anything else.

const SR = 48000;

export const SCALES: Record<string, number[]> = {
  "Major triad (+oct)": [0, 4, 7],
  "Minor triad": [0, 3, 7],
  "Major 7th": [0, 4, 7, 11],
  "Minor 7th": [0, 3, 7, 10],
  "Sus2": [0, 2, 7],
  "Sus4": [0, 5, 7],
  "Major pentatonic": [0, 2, 4, 7, 9],
  "Minor pentatonic": [0, 3, 5, 7, 10],
  "Octaves": [0, 12],
  "Whole tone": [0, 2, 4, 6, 8, 10],
};

export type ArpDirection = "up" | "down" | "updown" | "random";

export interface ArpParams {
  cyclePeriod: number; // s between arpeggios
  noteCount: number; // notes per roll
  stride: number; // s between notes
  humanize: number; // s random timing wobble
  direction: ArpDirection;
  attack: number; // s bloom
  decay: number; // s ring
  brightness: number; // partial count 1..8
  detune: number; // fractional
  tremRate: number; // Hz
  tremDepth: number;
  rootSemi: number; // semitones above A2 (110 Hz); 12 = A3
  scale: keyof typeof SCALES & string;
  warmth: number; // low-pass Hz
  gain: number;
  urgency: number; // 0..1 master attention knob
  buildMinutes: number;
}

// P3 — the tuned defaults from arp-lab (see memory: chamber attention cue).
export const ARP_DEFAULTS: ArpParams = {
  cyclePeriod: 4.5, noteCount: 4, stride: 0.18, humanize: 0.0, direction: "up",
  attack: 0.05, decay: 1.4, brightness: 2, detune: 0.003, tremRate: 5, tremDepth: 0.08,
  rootSemi: 12, scale: "Major triad (+oct)", warmth: 9000,
  gain: 0.08, urgency: 0.0, buildMinutes: 0.5,
};

const NOTE_NAMES = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
const A3 = 220.0;

export function rootHz(p: ArpParams): number {
  return A3 * Math.pow(2, (p.rootSemi - 12) / 12);
}
export function noteName(freq: number): string {
  const midi = Math.round(69 + 12 * Math.log2(freq / 440));
  return NOTE_NAMES[((midi % 12) + 12) % 12] + (Math.floor(midi / 12) - 1);
}

/** Urgency-adjusted effective params: louder + faster + more voices + brighter. */
export function arpEff(p: ArpParams) {
  const u = p.urgency;
  return {
    cyclePeriod: p.cyclePeriod * (1 - 0.6 * u),
    noteCount: Math.min(8, p.noteCount + Math.round(3 * u)),
    brightness: Math.min(8, p.brightness + Math.round(4 * u)),
    gain: Math.min(1.0, p.gain * (1 + 2.5 * u)),
  };
}

function pulseNote(freq: number, durNote: number, e: { brightness: number; detune: number; attack: number; decay: number; tremRate: number; tremDepth: number }): Float32Array {
  const n = Math.max(1, Math.floor(durNote * SR));
  const sig = new Float32Array(n);
  for (let p = 1; p <= e.brightness; p++) {
    const amp = 1 / Math.pow(p, 1.3);
    for (const det of [-e.detune, e.detune]) {
      const w = (2 * Math.PI * freq * p * (1 + det)) / SR;
      const ph = Math.random() * 2 * Math.PI;
      for (let i = 0; i < n; i++) sig[i] += amp * Math.sin(w * i + ph);
    }
  }
  const ai = Math.max(1, Math.floor(e.attack * SR));
  let peak = 1e-9;
  for (let i = 0; i < n; i++) {
    const t = i / SR;
    const env = i < ai ? 0.5 - 0.5 * Math.cos((Math.PI * i) / ai) : Math.exp(-(t - e.attack) / e.decay);
    const trem = 1 + e.tremDepth * Math.sin(2 * Math.PI * e.tremRate * t);
    sig[i] *= env * trem;
    const a = Math.abs(sig[i]);
    if (a > peak) peak = a;
  }
  for (let i = 0; i < n; i++) sig[i] /= peak;
  return sig;
}

function onepoleLP(buf: Float32Array, cutoff: number): void {
  if (cutoff >= 15500) return;
  const a = Math.exp((-2 * Math.PI * cutoff) / SR);
  const b = 1 - a;
  let y = 0;
  for (let i = 0; i < buf.length; i++) {
    y = b * buf[i] + a * y;
    buf[i] = y;
  }
}

function seqIndices(count: number, dir: ArpDirection): number[] {
  const up = Array.from({ length: count }, (_, i) => i);
  if (dir === "down") return up.slice().reverse();
  if (dir === "updown") return up.concat(up.slice(1, -1).reverse());
  if (dir === "random") {
    const s = up.slice();
    for (let i = s.length - 1; i > 0; i--) {
      const j = Math.floor(Math.random() * (i + 1));
      [s[i], s[j]] = [s[j], s[i]];
    }
    return s;
  }
  return up;
}

/** Render one full arpeggio cycle as a seamless loop (notes wrap-add across the end). */
export function buildArpCycle(p: ArpParams): Float32Array {
  const E = arpEff(p);
  const cycleLen = Math.max(1, Math.floor(E.cyclePeriod * SR));
  const buf = new Float32Array(cycleLen);
  const scale = SCALES[p.scale] ?? SCALES["Major triad (+oct)"];
  const root = rootHz(p);
  const order = seqIndices(E.noteCount, p.direction);
  const noteDur = Math.min(p.attack + p.decay * 5, E.cyclePeriod * 1.5); // include the tail
  for (let k = 0; k < order.length; k++) {
    const deg = order[k];
    const semi = scale[deg % scale.length] + 12 * Math.floor(deg / scale.length);
    const freq = root * Math.pow(2, semi / 12);
    const note = pulseNote(freq, noteDur, { ...p, brightness: E.brightness });
    const jitter = p.humanize ? (Math.random() * 2 - 1) * p.humanize : 0;
    const start = Math.floor((0.05 + k * p.stride + jitter) * SR);
    for (let i = 0; i < note.length; i++) buf[(((start + i) % cycleLen) + cycleLen) % cycleLen] += note[i];
  }
  onepoleLP(buf, p.warmth);
  let peak = 1e-9;
  for (const v of buf) if (Math.abs(v) > peak) peak = Math.abs(v);
  const norm = 0.5 / peak; // fixed source level; the engine gain does loudness
  for (let i = 0; i < buf.length; i++) buf[i] *= norm;
  return buf;
}
