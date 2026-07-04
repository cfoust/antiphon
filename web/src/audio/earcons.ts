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

/** The working drone: a machine hum at the very bottom of the agent's register —
 *  root, minor third and fifth three octaves below the ping (≈50–110 Hz), each
 *  with a touch of second harmonic so it reads on headphones down there, each
 *  rolling on its own slow rate so it turns over instead of pulsing. Seamless
 *  4 s loop (all carriers + rolls complete whole cycles). Mirrors AudioGen.swift. */
export function makeDrone(ctx: BaseAudioContext, ping: number): AudioBuffer {
  const dur = 4.0;
  const root = Math.round((ping / 8) * dur) / dur;
  const tones = [1.0, Math.pow(2, 3 / 12), Math.pow(2, 7 / 12)].map(
    (r) => Math.round(root * r * dur) / dur,
  );
  const amps = [0.5, 0.26, 0.24]; // root-heavy — it should sit low
  const rates = [0.25, 0.5, 0.75]; // whole cycles over the loop
  const phases = [0.0, 2.1, 4.2];
  return bake(ctx, dur, (t) => {
    let s = 0;
    for (let k = 0; k < 3; k++) {
      const roll = 0.7 + 0.3 * Math.sin(TAU * rates[k] * t + phases[k]);
      const tone = Math.sin(TAU * tones[k] * t) + 0.35 * Math.sin(TAU * tones[k] * 2 * t);
      s += tone * amps[k] * roll;
    }
    return s * 0.16;
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
