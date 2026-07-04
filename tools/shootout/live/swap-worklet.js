// Antiphon live A/B swap worklet — the realtime, head-tracked counterpart to the offline shootout.
//
// Holds N wasm engines (each = one candidate's antiphon-ffi build, instantiated from raw bytes into
// its own linear memory). Every quantum it runs BOTH engines of the current A/B pair on the SAME
// source + head pose, then equal-power crossfades between their outputs. Because both engines run
// continuously, their reverb tails stay warm, so flipping A<->B is instant and click-free. A
// per-engine loudness trim (precomputed offline to -23 LUFS) is applied so the blind A/B measures
// rendering, not loudness.
//
// Messages (from the page):
//   {type:"engine", id, wasm(ArrayBuffer), asset(ArrayBuffer), trim}  -> instantiate + create renderer
//   {type:"unload", id}                                               -> drop an engine (free the pair budget)
//   {type:"pair", a, b}                                               -> set the current A/B pair
//   {type:"select", side}                                             -> 0=A, 1=B (ramped crossfade)
//   {type:"source", samples?, x,y,z, send?, gain?, play?}             -> the one world-fixed voice
//   {type:"pose", pose:{px,py,pz,qw,qx,qy,qz}}                        -> listener head pose
//   {type:"room", index}                                             -> set room preset on all engines

const BLOCK = 128;
const XFADE_SEC = 0.012; // click-free A/B switch

class SwapProcessor extends AudioWorkletProcessor {
  constructor() {
    super();
    this.engines = new Map(); // id -> {ex, r, inPtr, inTab, srcArr, outL, outR, poseP, trim}
    this.pair = [null, null];
    this.sel = 0; // target side: 0 = A, 1 = B
    this.mix = 0; // current crossfade position 0..1 (0 = A, 1 = B)
    this.mixStep = 1 / (XFADE_SEC * sampleRate);
    this.src = { buf: null, cursor: 0, x: 0, y: 0, z: -1, send: 0.3, gain: 1, playing: false };
    this.pose = { px: 0, py: 0, pz: 0, qw: 1, qx: 0, qy: 0, qz: 0 };
    this.roomIndex = 1; // "room" (FDN) — matches the offline shootout scene
    this.block = new Float32Array(BLOCK);
    this.port.onmessage = (e) => this.onMsg(e.data);
  }

  async onMsg(d) {
    switch (d.type) {
      case "engine":
        await this.addEngine(d);
        break;
      case "unload":
        this.engines.delete(d.id);
        break;
      case "pair":
        this.pair = [d.a, d.b];
        this.sel = 0;
        this.mix = 0;
        this.port.postMessage({
          type: "pairReady",
          a: d.a, b: d.b,
          have: [this.engines.has(d.a), this.engines.has(d.b)],
        });
        break;
      case "select":
        this.sel = d.side ? 1 : 0;
        break;
      case "source":
        if (d.samples) { this.src.buf = d.samples; this.src.cursor = 0; this.src.playing = true; }
        if (d.x !== undefined) { this.src.x = d.x; this.src.y = d.y; this.src.z = d.z; }
        if (d.send !== undefined) this.src.send = d.send;
        if (d.gain !== undefined) this.src.gain = d.gain;
        if (d.play !== undefined) this.src.playing = d.play;
        break;
      case "pose":
        this.pose = d.pose;
        break;
      case "room":
        this.roomIndex = d.index >>> 0;
        for (const e of this.engines.values()) e.ex.antiphon_renderer_set_room(e.r, this.roomIndex);
        break;
    }
  }

  async addEngine(d) {
    if (this.engines.has(d.id)) { this.port.postMessage({ type: "engineReady", id: d.id }); return; }
    const { instance } = await WebAssembly.instantiate(d.wasm, {});
    const ex = instance.exports;
    const asset = new Uint8Array(d.asset);
    const aptr = ex.antiphon_alloc(asset.length);
    new Uint8Array(ex.memory.buffer, aptr, asset.length).set(asset);
    const r = ex.antiphon_renderer_create(aptr, asset.length, sampleRate, 1, BLOCK);
    if (!r) { this.port.postMessage({ type: "engineError", id: d.id }); return; }
    ex.antiphon_renderer_set_room(r, this.roomIndex);
    ex.antiphon_renderer_set_master_gain(r, 0.9);
    const eng = {
      ex, r,
      inPtr: ex.antiphon_alloc(BLOCK * 4),
      inTab: ex.antiphon_alloc(4),
      srcArr: ex.antiphon_alloc(10 * 4),
      outL: ex.antiphon_alloc(BLOCK * 4),
      outR: ex.antiphon_alloc(BLOCK * 4),
      poseP: ex.antiphon_alloc(7 * 4),
      trim: d.trim ?? 1,
    };
    new DataView(ex.memory.buffer).setUint32(eng.inTab, eng.inPtr, true); // inputs[0] = inPtr
    this.engines.set(d.id, eng);
    this.port.postMessage({ type: "engineReady", id: d.id });
  }

  // Advance the single shared source once; both engines consume an identical input block.
  fillBlock(n) {
    const b = this.block, s = this.src;
    if (!s.buf || !s.playing) { b.fill(0); return; }
    const buf = s.buf, len = buf.length;
    let c = s.cursor;
    for (let k = 0; k < n; k++) { if (c >= len) c = 0; b[k] = buf[c] * s.gain; c++; }
    s.cursor = c;
  }

  runEngine(eng, n) {
    const ex = eng.ex;
    const heap = new Float32Array(ex.memory.buffer);
    const dv = new DataView(ex.memory.buffer);
    heap.set(this.block.subarray(0, n), eng.inPtr / 4);
    const so = eng.srcArr;
    dv.setFloat32(so, this.src.x, true);
    dv.setFloat32(so + 4, this.src.y, true);
    dv.setFloat32(so + 8, this.src.z, true);
    dv.setFloat32(so + 12, 1.0, true);
    dv.setFloat32(so + 16, this.src.send, true);
    // facing/directivity/extent: zero = omni point source (struct is 10 floats now)
    for (let i = 5; i < 10; i++) dv.setFloat32(so + i * 4, 0, true);
    dv.setUint32(eng.inTab, eng.inPtr, true);
    const p = this.pose;
    const pv = [p.px, p.py, p.pz, p.qw, p.qx, p.qy, p.qz];
    for (let i = 0; i < 7; i++) dv.setFloat32(eng.poseP + i * 4, pv[i], true);
    ex.antiphon_renderer_process(eng.r, eng.poseP, eng.srcArr, 1, eng.inTab, eng.outL, eng.outR, n);
  }

  process(_inputs, outputs) {
    const out = outputs[0];
    const n = out[0].length;
    const A = this.engines.get(this.pair[0]);
    const B = this.engines.get(this.pair[1]);
    const ol = out[0], or = out[1];
    if (!A && !B) { ol.fill(0); or.fill(0); return true; }

    this.fillBlock(n);
    if (A) this.runEngine(A, n);
    if (B) this.runEngine(B, n);

    const ha = A ? new Float32Array(A.ex.memory.buffer) : null;
    const hb = B ? new Float32Array(B.ex.memory.buffer) : null;
    const aL = A ? A.outL / 4 : 0, aR = A ? A.outR / 4 : 0;
    const bL = B ? B.outL / 4 : 0, bR = B ? B.outR / 4 : 0;
    const trimA = A ? A.trim : 0, trimB = B ? B.trim : 0;
    const target = this.sel;

    for (let k = 0; k < n; k++) {
      if (this.mix < target) this.mix = Math.min(target, this.mix + this.mixStep);
      else if (this.mix > target) this.mix = Math.max(target, this.mix - this.mixStep);
      const gA = Math.cos(this.mix * 0.5 * Math.PI); // equal-power crossfade
      const gB = Math.sin(this.mix * 0.5 * Math.PI);
      let l = 0, r = 0;
      if (A && gA > 0) { const la = ha[aL + k], ra = ha[aR + k]; l += (la === la ? la : 0) * trimA * gA; r += (ra === ra ? ra : 0) * trimA * gA; }
      if (B && gB > 0) { const lb = hb[bL + k], rb = hb[bR + k]; l += (lb === lb ? lb : 0) * trimB * gB; r += (rb === rb ? rb : 0) * trimB * gB; }
      ol[k] = l; or[k] = r;
    }
    return true;
  }
}

registerProcessor("antiphon-swap", SwapProcessor);
