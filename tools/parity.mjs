// Cross-target parity check: drive the wasm-compiled engine through the SAME
// deterministic scene as `chamber-render parity` and compare to its float dump.
//
//   1) cargo run -p chamber-render --release -- parity
//   2) cargo build -p chamber-ffi --release --target wasm32-unknown-unknown
//   3) node tools/parity.mjs
//
// Passes if native vs wasm RMS error is below -90 dBFS (float-rounding tolerance).

import { readFileSync } from "node:fs";

const WASM = "target/wasm32-unknown-unknown/release/chamber_ffi.wasm";
const ASSET = "assets/baked/chamber-default.chamber";
const BLOCK = 128;

const wasmBytes = readFileSync(WASM);
const asset = readFileSync(ASSET);
const inputBin = readFileSync("out/parity_input.bin");
const nativeBin = readFileSync("out/parity_native.f32");

const { instance } = await WebAssembly.instantiate(wasmBytes, {});
const ex = instance.exports;
const mem = () => new DataView(ex.memory.buffer);
const f32 = () => new Float32Array(ex.memory.buffer);

// stage the asset blob
const assetPtr = ex.chamber_alloc(asset.length);
new Uint8Array(ex.memory.buffer, assetPtr, asset.length).set(asset);

const SR = 48000;
const r = ex.chamber_renderer_create(assetPtr, asset.length, SR, 1, BLOCK);
if (r === 0) throw new Error("renderer_create failed");
ex.chamber_renderer_set_room(r, 0);
ex.chamber_renderer_set_master_gain(r, 0.9);

const input = new Float32Array(
  inputBin.buffer,
  inputBin.byteOffset,
  inputBin.byteLength / 4
);
const total = input.length;

// scratch buffers in wasm memory
const inPtr = ex.chamber_alloc(BLOCK * 4);
const outLPtr = ex.chamber_alloc(BLOCK * 4);
const outRPtr = ex.chamber_alloc(BLOCK * 4);
// pose (7 floats) + source (5 floats) + input-pointer table (1 ptr)
const posePtr = ex.chamber_alloc(7 * 4);
const srcPtr = ex.chamber_alloc(5 * 4);
const inTabPtr = ex.chamber_alloc(4);

// identity pose
{
  const dv = mem();
  for (let i = 0; i < 7; i++) dv.setFloat32(posePtr + i * 4, i === 3 ? 1 : 0, true); // qw=1
}
// source at (0.9, 0, -1.3), gain 0.9, send 0.35
{
  const dv = mem();
  const s = [0.9, 0.0, -1.3, 0.9, 0.35];
  s.forEach((v, i) => dv.setFloat32(srcPtr + i * 4, v, true));
  dv.setUint32(inTabPtr, inPtr, true); // inputs[0] = inPtr
}

const out = new Float32Array(total * 2);
let pos = 0;
while (pos < total) {
  const n = Math.min(BLOCK, total - pos);
  f32().set(input.subarray(pos, pos + n), inPtr / 4);
  ex.chamber_renderer_process(r, posePtr, srcPtr, 1, inTabPtr, outLPtr, outRPtr, n);
  const fl = f32();
  for (let i = 0; i < n; i++) {
    out[(pos + i) * 2] = fl[outLPtr / 4 + i];
    out[(pos + i) * 2 + 1] = fl[outRPtr / 4 + i];
  }
  pos += n;
}

const native = new Float32Array(
  nativeBin.buffer,
  nativeBin.byteOffset,
  nativeBin.byteLength / 4
);

let sumSq = 0,
  maxAbs = 0,
  sig = 0;
const N = Math.min(native.length, out.length);
for (let i = 0; i < N; i++) {
  const d = out[i] - native[i];
  sumSq += d * d;
  sig += native[i] * native[i];
  if (Math.abs(d) > maxAbs) maxAbs = Math.abs(d);
}
const rms = Math.sqrt(sumSq / N);
const rmsDb = 20 * Math.log10(rms + 1e-20);
const sigDb = 20 * Math.log10(Math.sqrt(sig / N) + 1e-20);
console.log(`compared ${N} samples`);
console.log(`signal RMS:   ${sigDb.toFixed(1)} dBFS`);
console.log(`error RMS:    ${rmsDb.toFixed(1)} dBFS`);
console.log(`max abs diff: ${maxAbs.toExponential(2)}`);
const pass = rmsDb < -90;
console.log(pass ? "PARITY PASS (error < -90 dBFS)" : "PARITY FAIL");
process.exit(pass ? 0 : 1);
