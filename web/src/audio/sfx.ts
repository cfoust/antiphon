// Procedural sci-fi sound effects for the test harness — no asset files needed. Each
// returns a mono Float32Array at the given sample rate. `loop` ones are seamless beds.

function buf(sr: number, secs: number): Float32Array {
  return new Float32Array(Math.floor(sr * secs));
}
// tiny deterministic PRNG so presets are stable
function rng(seed: number) {
  let s = seed >>> 0;
  return () => ((s = (s * 1664525 + 1013904223) >>> 0) / 0xffffffff) * 2 - 1;
}
const TAU = Math.PI * 2;

export interface Sfx { name: string; loop: boolean; make: (sr: number) => Float32Array; }

export const SFX: Sfx[] = [
  {
    name: "laser", loop: false, make: (sr) => {
      const y = buf(sr, 0.5);
      for (let i = 0; i < y.length; i++) {
        const t = i / sr;
        const f = 1800 * Math.exp(-t * 9) + 200;
        y[i] = Math.sin(TAU * f * t) * Math.exp(-t * 7) * 0.7;
      }
      return y;
    },
  },
  {
    name: "blip", loop: false, make: (sr) => {
      const y = buf(sr, 0.18);
      for (let i = 0; i < y.length; i++) {
        const t = i / sr;
        y[i] = (Math.sin(TAU * 880 * t) + 0.5 * Math.sin(TAU * 1320 * t)) * Math.exp(-t * 24) * 0.6;
      }
      return y;
    },
  },
  {
    name: "comm beep", loop: false, make: (sr) => {
      const y = buf(sr, 0.6);
      for (let i = 0; i < y.length; i++) {
        const t = i / sr;
        const gate = t < 0.12 || (t > 0.2 && t < 0.32) ? 1 : 0;
        y[i] = Math.sin(TAU * 1046 * t) * gate * 0.5;
      }
      return y;
    },
  },
  {
    name: "zap (broadband)", loop: false, make: (sr) => {
      const y = buf(sr, 0.4);
      const r = rng(7);
      let lp = 0;
      for (let i = 0; i < y.length; i++) {
        const t = i / sr;
        const n = r();
        lp += 0.5 * (n - lp);
        y[i] = (0.7 * lp + 0.3 * Math.sin(TAU * (400 + 1500 * Math.exp(-t * 12)) * t)) * Math.exp(-t * 11) * 0.8;
      }
      return y;
    },
  },
  {
    name: "sweep up", loop: false, make: (sr) => {
      const y = buf(sr, 1.2);
      for (let i = 0; i < y.length; i++) {
        const t = i / sr;
        const f = 120 * Math.pow(2, t * 4);
        const env = Math.min(1, t * 4) * Math.exp(-Math.max(0, t - 0.9) * 8);
        y[i] = (Math.sin(TAU * f * t) + 0.4 * Math.sin(TAU * f * 2 * t)) * env * 0.4;
      }
      return y;
    },
  },
  {
    name: "alarm", loop: true, make: (sr) => {
      const y = buf(sr, 1.0);
      for (let i = 0; i < y.length; i++) {
        const t = i / sr;
        const f = 700 + 250 * Math.sin(TAU * 3 * t);
        y[i] = Math.sin(TAU * f * t) * 0.45 * (0.6 + 0.4 * Math.sign(Math.sin(TAU * 2 * t)));
      }
      return y;
    },
  },
  {
    name: "drone (bed)", loop: true, make: (sr) => {
      const y = buf(sr, 4.0);
      for (let i = 0; i < y.length; i++) {
        const t = i / sr;
        y[i] = (Math.sin(TAU * 55 * t) * 0.5 + Math.sin(TAU * 110.3 * t) * 0.28 +
          Math.sin(TAU * 165 * t) * 0.15 + Math.sin(TAU * 82.7 * t) * 0.2) *
          (0.7 + 0.3 * Math.sin(TAU * 0.13 * t)) * 0.4;
      }
      return y;
    },
  },
  {
    name: "engine hum (bed)", loop: true, make: (sr) => {
      const y = buf(sr, 3.0);
      const r = rng(42);
      let lp = 0;
      for (let i = 0; i < y.length; i++) {
        const t = i / sr;
        lp += 0.02 * (r() - lp);
        y[i] = (Math.sin(TAU * 70 * t) * 0.4 + lp * 0.5 + Math.sin(TAU * 140 * t) * 0.15) * 0.4;
      }
      return y;
    },
  },
  {
    name: "white noise (bed)", loop: true, make: (sr) => {
      const y = buf(sr, 2.0);
      const r = rng(1);
      for (let i = 0; i < y.length; i++) y[i] = r() * 0.3;
      return y;
    },
  },
  {
    name: "ping (pure sine)", loop: false, make: (sr) => {
      const y = buf(sr, 0.6);
      for (let i = 0; i < y.length; i++) {
        const t = i / sr;
        y[i] = (Math.sin(TAU * 587 * t) * 0.5 + Math.sin(TAU * 880 * t) * 0.22) * Math.exp(-t * 7);
      }
      return y;
    },
  },
];
