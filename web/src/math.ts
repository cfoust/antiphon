import type { Arrangement } from "./types";

export const TAU = Math.PI * 2;
export const deg = (r: number) => (r * 180) / Math.PI;
export const rad = (d: number) => (d * Math.PI) / 180;

/** Smallest signed angle from b to a, in radians, wrapped to [-π, π]. */
export function angdiff(a: number, b: number): number {
  let d = (a - b) % TAU;
  if (d > Math.PI) d -= TAU;
  if (d < -Math.PI) d += TAU;
  return d;
}

/** Bearing (radians, 0 = front, clockwise) for each agent index, per arrangement. */
export const ARRANGE: Record<Arrangement, (n: number) => number[]> = {
  ring: (n) => Array.from({ length: n }, (_, i) => (i / n) * TAU),
  // semicircle across the front: left (−90°) → front (0°) → right (+90°)
  arc: (n) =>
    n === 1 ? [0] : Array.from({ length: n }, (_, i) => rad(-90 + (180 * i) / (n - 1))),
  cluster: (n) =>
    n === 1 ? [0] : Array.from({ length: n }, (_, i) => rad(-32 + (64 * i) / (n - 1))),
};
