// Chamber AudioWorklet — runs the Rust binaural engine (chamber-ffi) on the audio thread.
// Classic script (no imports). Generic N-source spatializer driven from the main thread:
// each source has a mono sample buffer, a 3D position and gain; the listener has a 6DoF pose.
// This is the shared audio core for BOTH the Chamber app and the test harness.

const BLOCK = 128;

class ChamberProcessor extends AudioWorkletProcessor {
  constructor(options) {
    super();
    this.ready = false;
    this.ex = null;
    this.maxSources = (options.processorOptions && options.processorOptions.maxSources) || 16;
    this.sources = new Map(); // id -> {buf, cursor, gain, x,y,z, loop, playing}
    this.inputCfg = []; // per live audio-input source: {x,y,z,gain,send}
    this.pose = { qw: 1, qx: 0, qy: 0, qz: 0, px: 0, py: 0, pz: 0 };
    this.port.onmessage = (e) => this.onMsg(e.data);
  }

  async onMsg(d) {
    switch (d.type) {
      case "init":
        await this.init(d);
        break;
      case "src": {
        let s = this.sources.get(d.id);
        if (!s) {
          s = { buf: null, cursor: 0, gain: 1, x: 0, y: 0, z: -1, send: 0.3, loop: true, playing: false };
          this.sources.set(d.id, s);
        }
        if (d.samples) { s.buf = d.samples; s.cursor = 0; }
        if (d.gain !== undefined) s.gain = d.gain;
        if (d.x !== undefined) { s.x = d.x; s.y = d.y; s.z = d.z; }
        if (d.send !== undefined) s.send = d.send;
        if (d.loop !== undefined) s.loop = d.loop;
        if (d.play) { s.cursor = 0; s.playing = true; }
        if (d.stop) s.playing = false;
        if (s.loop && s.buf) s.playing = true;
        break;
      }
      case "remove":
        this.sources.delete(d.id);
        break;
      case "inputCfg":
        this.inputCfg[d.index] = { x: d.x, y: d.y, z: d.z, gain: d.gain ?? 1, send: d.send ?? 0.3 };
        break;
      case "pose":
        this.pose = d;
        break;
      case "room":
        if (this.ready) this.ex.chamber_renderer_set_room(this.r, d.index >>> 0);
        break;
      case "reflections":
        if (this.ready) this.ex.chamber_renderer_set_reflections(this.r, d.on ? 1 : 0);
        break;
      case "master":
        if (this.ready) this.ex.chamber_renderer_set_master_gain(this.r, d.gain);
        break;
      case "attnAgents": // "an agent is waiting" cue: number of waiting agents (0 = silent)
        if (this.ready) this.ex.chamber_renderer_set_attention_agents(this.r, d.n >>> 0);
        break;
      case "attnBuild": // minutes to ramp the cue from silent -> full urgency
        if (this.ready) this.ex.chamber_renderer_set_attention_build_minutes(this.r, d.minutes);
        break;
      case "immersion": // eyes fade target 0..1 (1 = scene full/cue silent), applied per-source in-engine
        if (this.ready) this.ex.chamber_renderer_set_immersion(this.r, d.value);
        break;
      case "freqScale": // HRTF "fit": warps the pinna spectral cue (dsp clamps 0.5..2.2)
        this.freqScale = d.value;
        if (this.ready) this.ex.chamber_renderer_set_freq_scale(this.r, d.value);
        break;
    }
  }

  async init(d) {
    const { instance } = await WebAssembly.instantiate(d.wasm, {});
    const ex = (this.ex = instance.exports);
    const asset = new Uint8Array(d.asset);
    const aptr = ex.chamber_alloc(asset.length);
    new Uint8Array(ex.memory.buffer, aptr, asset.length).set(asset);
    this.r = ex.chamber_renderer_create(aptr, asset.length, sampleRate, this.maxSources, BLOCK);
    this.numRooms = ex.chamber_renderer_num_rooms(this.r);
    ex.chamber_renderer_set_master_gain(this.r, 0.9);
    if (this.freqScale !== undefined) ex.chamber_renderer_set_freq_scale(this.r, this.freqScale);
    // preallocate wasm scratch
    this.inPtrs = [];
    for (let i = 0; i < this.maxSources; i++) this.inPtrs.push(ex.chamber_alloc(BLOCK * 4));
    this.inTab = ex.chamber_alloc(this.maxSources * 4);
    this.srcArr = ex.chamber_alloc(this.maxSources * 5 * 4);
    this.outL = ex.chamber_alloc(BLOCK * 4);
    this.outR = ex.chamber_alloc(BLOCK * 4);
    this.poseP = ex.chamber_alloc(7 * 4);
    this.ready = true;
    this.port.postMessage({ type: "ready", numRooms: this.numRooms });
  }

  process(inputs, outputs) {
    const out = outputs[0];
    if (!this.ready) return true;
    const n = out[0].length;
    const ex = this.ex;
    const heap = new Float32Array(ex.memory.buffer);
    const dv = new DataView(ex.memory.buffer);

    let idx = 0;
    // live audio inputs become sources (used by the Chamber app: one mono input per agent)
    for (let i = 0; i < inputs.length && idx < this.maxSources; i++) {
      const ch = inputs[i][0];
      if (!ch) continue; // input not connected
      const cfg = this.inputCfg[i] || { x: 0, y: 0, z: -1, gain: 1, send: 0.3 };
      const inBase = this.inPtrs[idx] / 4;
      const g = cfg.gain;
      for (let k = 0; k < n; k++) heap[inBase + k] = ch[k] * g;
      const so = this.srcArr + idx * 5 * 4;
      dv.setFloat32(so, cfg.x, true);
      dv.setFloat32(so + 4, cfg.y, true);
      dv.setFloat32(so + 8, cfg.z, true);
      dv.setFloat32(so + 12, 1.0, true);
      dv.setFloat32(so + 16, cfg.send, true);
      dv.setUint32(this.inTab + idx * 4, this.inPtrs[idx], true);
      idx++;
    }

    // collect active buffer sources (harness), up to maxSources
    for (const s of this.sources.values()) {
      if (idx >= this.maxSources || !s.buf || !s.playing) continue;
      const inBase = this.inPtrs[idx] / 4;
      const buf = s.buf;
      const len = buf.length;
      let c = s.cursor;
      let finished = false;
      for (let k = 0; k < n; k++) {
        if (c >= len) {
          if (s.loop) { c = 0; }
          else { heap[inBase + k] = 0; finished = true; continue; } // never read past the end (was NaN)
        }
        heap[inBase + k] = buf[c] * s.gain;
        c++;
      }
      s.cursor = c;
      if (finished) s.playing = false;
      // source struct: x,y,z,gain(=1, already applied),send
      const so = this.srcArr + idx * 5 * 4;
      dv.setFloat32(so, s.x, true);
      dv.setFloat32(so + 4, s.y, true);
      dv.setFloat32(so + 8, s.z, true);
      dv.setFloat32(so + 12, 1.0, true);
      dv.setFloat32(so + 16, s.send ?? 0.3, true);
      dv.setUint32(this.inTab + idx * 4, this.inPtrs[idx], true);
      idx++;
    }

    // pose
    const p = this.pose;
    const pv = [p.px, p.py, p.pz, p.qw, p.qx, p.qy, p.qz];
    for (let i = 0; i < 7; i++) dv.setFloat32(this.poseP + i * 4, pv[i], true);

    ex.chamber_renderer_process(this.r, this.poseP, this.srcArr, idx, this.inTab, this.outL, this.outR, n);

    const h = new Float32Array(ex.memory.buffer); // re-view (may have grown)
    const lo = this.outL / 4, ro = this.outR / 4;
    const ol = out[0], or = out[1];
    for (let k = 0; k < n; k++) {
      const l = h[lo + k], r = h[ro + k];
      ol[k] = l === l ? l : 0; // NaN backstop (NaN !== NaN)
      or[k] = r === r ? r : 0;
    }
    return true;
  }
}

registerProcessor("chamber", ChamberProcessor);
