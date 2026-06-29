// AudioWorkletProcessor that runs the Chamber engine (wasm C-ABI) on the audio thread.
// Classic script (no imports). Receives the wasm bytes + asset blob via the port,
// instantiates synchronously-enough, and renders one 128-frame quantum per process().

class ChamberProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.ready = false;
    this.ex = null;
    this.r = 0;
    this.yaw = 0;
    this.pitch = 0;
    this.srcPos = [0.9, 0.0, -1.3]; // default: front-right
    this.numRooms = 1;
    this.port.onmessage = (e) => this.onMsg(e.data);
  }

  async onMsg(d) {
    if (d.type === "init") {
      await this.init(d);
    } else if (d.type === "pose") {
      this.yaw = d.yaw;
      this.pitch = d.pitch || 0;
    } else if (d.type === "src") {
      this.srcPos = d.pos;
    } else if (d.type === "room" && this.ready) {
      this.ex.chamber_renderer_set_room(this.r, d.room >>> 0);
    }
  }

  async init(d) {
    const { instance } = await WebAssembly.instantiate(d.wasm, {});
    const ex = instance.exports;
    this.ex = ex;
    const BLOCK = 128;

    // stage asset
    const asset = new Uint8Array(d.asset);
    const aptr = ex.chamber_alloc(asset.length);
    new Uint8Array(ex.memory.buffer, aptr, asset.length).set(asset);
    this.r = ex.chamber_renderer_create(aptr, asset.length, sampleRate, 1, BLOCK);
    this.numRooms = ex.chamber_renderer_num_rooms(this.r);
    ex.chamber_renderer_set_master_gain(this.r, 0.9);
    ex.chamber_renderer_set_room(this.r, 1); // a small room by default

    // scratch buffers in wasm memory
    this.inPtr = ex.chamber_alloc(BLOCK * 4);
    this.outLPtr = ex.chamber_alloc(BLOCK * 4);
    this.outRPtr = ex.chamber_alloc(BLOCK * 4);
    this.posePtr = ex.chamber_alloc(7 * 4);
    this.srcPtr = ex.chamber_alloc(5 * 4);
    this.inTabPtr = ex.chamber_alloc(4);
    new DataView(ex.memory.buffer).setUint32(this.inTabPtr, this.inPtr, true);

    // source signal: a looping voice-like buffer (matches the offline demos)
    this.sig = makeVoice(sampleRate, 220);
    this.sigPos = 0;
    this.BLOCK = BLOCK;
    this.ready = true;
    this.port.postMessage({ type: "ready", numRooms: this.numRooms });
  }

  writePose() {
    const dv = new DataView(this.ex.memory.buffer);
    // quaternion from yaw (about +y) and pitch (about +x)
    const cy = Math.cos(this.yaw * 0.5), sy = Math.sin(this.yaw * 0.5);
    const cp = Math.cos(this.pitch * 0.5), sp = Math.sin(this.pitch * 0.5);
    // q = qy * qx
    const qw = cy * cp, qx = cy * sp, qy = sy * cp, qz = -sy * sp;
    const f = [0, 0, 0, qw, qx, qy, qz];
    for (let i = 0; i < 7; i++) dv.setFloat32(this.posePtr + i * 4, f[i], true);
    const s = [this.srcPos[0], this.srcPos[1], this.srcPos[2], 0.9, 0.35];
    for (let i = 0; i < 5; i++) dv.setFloat32(this.srcPtr + i * 4, s[i], true);
  }

  process(_inputs, outputs) {
    const out = outputs[0];
    if (!this.ready) return true;
    const n = out[0].length; // 128
    const ex = this.ex;

    // fill input (loop the source signal)
    const heap = new Float32Array(ex.memory.buffer);
    const inBase = this.inPtr / 4;
    for (let i = 0; i < n; i++) {
      heap[inBase + i] = this.sig[this.sigPos];
      this.sigPos = (this.sigPos + 1) % this.sig.length;
    }

    this.writePose();
    ex.chamber_renderer_process(
      this.r, this.posePtr, this.srcPtr, 1, this.inTabPtr,
      this.outLPtr, this.outRPtr, n
    );

    const h = new Float32Array(ex.memory.buffer); // re-view (memory may have grown)
    out[0].set(h.subarray(this.outLPtr / 4, this.outLPtr / 4 + n));
    out[1].set(h.subarray(this.outRPtr / 4, this.outRPtr / 4 + n));
    return true;
  }
}

function makeVoice(sr, f0) {
  const dur = 3.0;
  const n = (dur * sr) | 0;
  const out = new Float32Array(n);
  const harm = [[1, 1], [2, 0.6], [3, 0.7], [4, 0.5], [5, 0.35], [7, 0.4], [9, 0.25], [11, 0.18]];
  for (let i = 0; i < n; i++) {
    const t = i / sr;
    const vib = 1 + 0.01 * Math.sin(2 * Math.PI * 5 * t);
    let s = 0;
    for (const [h, a] of harm) s += a * Math.sin(2 * Math.PI * f0 * h * vib * t);
    const g = Math.pow(0.5 - 0.5 * Math.cos(2 * Math.PI * 2.6 * t), 1.5);
    out[i] = 0.16 * s * g;
  }
  return out;
}

registerProcessor("chamber", ChamberProcessor);
