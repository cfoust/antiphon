import type { EnvName } from "../types";

/** Exponential-decay noise burst → a simple synthetic impulse response. */
export function makeIR(
  ctx: BaseAudioContext,
  seconds: number,
  decay: number,
  predelay = 0,
): AudioBuffer {
  const rate = ctx.sampleRate;
  const len = Math.max(1, Math.floor(rate * seconds));
  const buf = ctx.createBuffer(2, len, rate);
  for (let ch = 0; ch < 2; ch++) {
    const d = buf.getChannelData(ch);
    const pd = Math.floor(predelay * rate);
    for (let i = 0; i < len; i++) {
      if (i < pd) {
        d[i] = 0;
        continue;
      }
      const t = (i - pd) / (len - pd);
      d[i] = (Math.random() * 2 - 1) * Math.pow(1 - t, decay);
    }
  }
  return buf;
}

/** White-noise buffer used for the heard-state radio static. */
export function makeNoise(ctx: BaseAudioContext, seconds: number): AudioBuffer {
  const rate = ctx.sampleRate;
  const len = Math.floor(rate * seconds);
  const buf = ctx.createBuffer(1, len, rate);
  const d = buf.getChannelData(0);
  for (let i = 0; i < len; i++) d[i] = Math.random() * 2 - 1;
  return buf;
}

/** Impulse-response factory per environment. */
export const ENVS: Record<EnvName, (ctx: BaseAudioContext) => AudioBuffer> = {
  dry: (c) => makeIR(c, 0.25, 6.0),
  room: (c) => makeIR(c, 0.6, 4.0, 0.005),
  antiphon: (c) => makeIR(c, 1.6, 2.6, 0.012),
  hall: (c) => makeIR(c, 3.4, 1.7, 0.03),
};

/** Reverb send level per environment. */
export const wetLevel: Record<EnvName, number> = {
  dry: 0.1,
  room: 0.28,
  antiphon: 0.5,
  hall: 0.7,
};
