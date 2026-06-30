/**
 * The seat pool — mirrors src/agents.ts (same ids + colors) and pins each seat to
 * an ElevenLabs voice (the same voices generate.py uses for the canned clips), so a
 * live agent sounds like the seat it lands on. Sessions bind to seats in order.
 */
export interface Seat {
  id: string;
  color: string;
  voice: string;
}

export const ROSTER: Seat[] = [
  { id: "atlas", color: "#7aa2ff", voice: "JBFqnCBsd6RMkjVDRZzb" }, // George, warm British
  { id: "echo", color: "#9aa6b8", voice: "SAz9YHcvj6GT2YYXdXww" }, // River, calm neutral
  { id: "wren", color: "#5fd0c5", voice: "EXAVITQu4vr4xnSDxMaL" }, // Sarah, professional
  { id: "cass", color: "#ffce6b", voice: "IKne3meq5aSn9XLyUdCD" }, // Charlie, hyped
  { id: "iris", color: "#c08bff", voice: "Xb7hH8MSUJpSbSDYk0k2" }, // Alice, clear British
  { id: "rook", color: "#ff9d7a", voice: "bIHbv24MWmeRgasZH58o" }, // Will, relaxed
];
