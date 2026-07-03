// Chord-identity + drag-audition earcons, baked to AudioBuffers.
// The recipes mirror AudioGen.swift (makeToolNote / makeDrone / makePulse /
// toolNoteFreqs) sample-for-sample so the two hosts speak the same language:
// each agent's chord is a minor-7th built an octave below its ping frequency —
// tool calls walk DOWN the chord's top three tones (m7 → 5th → m3), and the
// chord's root is the agent's working drone.

const TAU = Math.PI * 2;

/** Bake a mono buffer at the context rate from a per-sample function of t (seconds). */
function bake(ctx: BaseAudioContext, dur: number, fn: (t: number) => number): AudioBuffer {
  const sr = ctx.sampleRate;
  const n = Math.floor(sr * dur);
  const buf = ctx.createBuffer(1, n, sr);
  const y = buf.getChannelData(0);
  for (let i = 0; i < n; i++) y[i] = fn(i / sr);
  return buf;
}

/** The three descending tool-call notes for a ping frequency (Hz, high→low). */
export function toolNoteFreqs(ping: number): number[] {
  const root = ping / 2;
  return [root * 2 ** (10 / 12), root * 2 ** (7 / 12), root * 2 ** (3 / 12)];
}

/** One tool-call note: a soft, round pluck — sine + a whisper of octave. */
export function makeToolNote(ctx: BaseAudioContext, freq: number): AudioBuffer {
  return bake(ctx, 0.9, (t) => {
    const env = Math.min(t / 0.008, 1) * Math.exp(-t * 4.2);
    const s = Math.sin(TAU * freq * t) * 0.85 + Math.sin(TAU * freq * 2 * t) * 0.1;
    return s * env * 0.16;
  });
}

/** The working drone: a seamless 4 s loop of the chord root, breathing at 0.5 Hz
 *  with a 0.25 Hz two-oscillator beat. All components complete whole cycles over
 *  the loop so it can run forever without a click. */
export function makeDrone(ctx: BaseAudioContext, ping: number): AudioBuffer {
  const dur = 4.0;
  // quantize the carrier to whole cycles over the loop (seamless)
  const f = Math.round((ping / 2) * dur) / dur;
  const f2 = f + 1.0 / dur; // exactly one extra cycle → a slow, warm beat
  return bake(ctx, dur, (t) => {
    const breathe = 0.62 + 0.38 * Math.sin(TAU * 0.5 * t - Math.PI / 2);
    const s = Math.sin(TAU * f * t) * 0.6 + Math.sin(TAU * f2 * t) * 0.4;
    return s * breathe * 0.16;
  });
}

/** Drag audition pulse: a sonar-ish blip once per 1.4 s loop, meant to be played
 *  with a hot reverb send so the room answers from the agent's spot. */
export function makePulse(ctx: BaseAudioContext, ping: number): AudioBuffer {
  const dur = 1.4;
  const f = Math.round(ping * dur) / dur;
  return bake(ctx, dur, (t) => {
    const env = Math.min(t / 0.006, 1) * Math.exp(-t * 5.5);
    const s = Math.sin(TAU * f * t) * 0.7 + Math.sin(TAU * (f / 2) * t) * 0.3;
    return s * env * 0.5;
  });
}
