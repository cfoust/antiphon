// WasmEngine — loads the Rust binaural engine (chamber-ffi) into an AudioWorklet and
// exposes a small, host-friendly API. This is the shared spatializer for the Chamber app
// and the test harness, and is the web half of "native + web, identical engine".

export interface Vec3 { x: number; y: number; z: number; }
export interface Quat { w: number; x: number; y: number; z: number; }

export interface SourceOpts {
  samples?: Float32Array; // mono signal (48 kHz assumed by the asset)
  gain?: number;
  pos?: Vec3;
  loop?: boolean;
  play?: boolean;
}

export class WasmEngine {
  node!: AudioWorkletNode;
  numRooms = 0;
  private ctx: AudioContext;
  private ready: Promise<void>;
  private resolveReady!: () => void;

  private constructor(ctx: AudioContext) {
    this.ctx = ctx;
    this.ready = new Promise((r) => (this.resolveReady = r));
  }

  /** Build the engine: fetch wasm + asset, add the worklet module, wire it to the output. */
  static async create(
    ctx: AudioContext,
    opts: { wasmUrl: string; assetUrl: string; maxSources?: number; workletUrl?: string; numInputs?: number },
  ): Promise<WasmEngine> {
    const e = new WasmEngine(ctx);
    const [wasm, asset] = await Promise.all([
      fetch(opts.wasmUrl).then((r) => r.arrayBuffer()),
      fetch(opts.assetUrl).then((r) => r.arrayBuffer()),
    ]);
    await ctx.audioWorklet.addModule(opts.workletUrl ?? "/chamber-worklet.js");
    e.node = new AudioWorkletNode(ctx, "chamber", {
      numberOfInputs: opts.numInputs ?? 0,
      numberOfOutputs: 1,
      outputChannelCount: [2],
      processorOptions: { maxSources: opts.maxSources ?? 16 },
    });
    e.node.port.onmessage = (ev) => {
      if (ev.data?.type === "ready") {
        e.numRooms = ev.data.numRooms;
        e.resolveReady();
      }
    };
    e.node.port.postMessage({ type: "init", wasm, asset }, [wasm, asset]);
    await e.ready;
    return e;
  }

  /** Connect the engine output (e.g. to ctx.destination or a master gain). */
  connect(dst: AudioNode): void {
    this.node.connect(dst);
  }

  /** Connect a WebAudio node to live-input source slot `i` (Chamber: one per agent). */
  connectInput(src: AudioNode, i: number): void {
    src.connect(this.node, 0, i);
  }

  /** Position/gain/send for a live-input source slot. */
  setInputCfg(i: number, cfg: { pos: Vec3; gain?: number; send?: number }): void {
    this.node.port.postMessage({
      type: "inputCfg", index: i,
      x: cfg.pos.x, y: cfg.pos.y, z: cfg.pos.z, gain: cfg.gain ?? 1, send: cfg.send ?? 0.3,
    });
  }

  /** Add or update a source. `samples` (transferable) replaces its buffer. */
  setSource(id: string, o: SourceOpts): void {
    const msg: Record<string, unknown> = { type: "src", id };
    if (o.samples) msg.samples = o.samples;
    if (o.gain !== undefined) msg.gain = o.gain;
    if (o.pos) { msg.x = o.pos.x; msg.y = o.pos.y; msg.z = o.pos.z; }
    if (o.loop !== undefined) msg.loop = o.loop;
    if (o.play !== undefined) msg.play = o.play;
    const transfer = o.samples ? [o.samples.buffer] : [];
    this.node.port.postMessage(msg, transfer);
  }

  /** Re-trigger a one-shot source from the start. */
  trigger(id: string): void { this.node.port.postMessage({ type: "src", id, play: true }); }
  removeSource(id: string): void { this.node.port.postMessage({ type: "remove", id }); }

  /** Listener pose. `orientYawRad` follows the app convention (forward = (sinθ,0,−cosθ)). */
  setPose(orientYawRad: number, pos: Vec3 = { x: 0, y: 0, z: 0 }): void {
    const h = 0.5 * orientYawRad;
    this.node.port.postMessage({
      type: "pose",
      qw: Math.cos(h), qx: 0, qy: -Math.sin(h), qz: 0,
      px: pos.x, py: pos.y, pz: pos.z,
    });
  }

  /** Full-quaternion pose (for 6DoF / pitch+roll). */
  setPoseQuat(q: Quat, pos: Vec3 = { x: 0, y: 0, z: 0 }): void {
    this.node.port.postMessage({ type: "pose", qw: q.w, qx: q.x, qy: q.y, qz: q.z, px: pos.x, py: pos.y, pz: pos.z });
  }

  /** HRTF "fit": warps the pinna spectral cue. The dsp clamps to 0.5..2.2. */
  setFreqScale(value: number): void { this.node.port.postMessage({ type: "freqScale", value }); }
  setRoom(index: number): void { this.node.port.postMessage({ type: "room", index }); }
  setReflections(on: boolean): void { this.node.port.postMessage({ type: "reflections", on }); }
  setMaster(gain: number): void { this.node.port.postMessage({ type: "master", gain }); }
}

/** Default asset/wasm URLs (staged into public/ by tools/build-web.sh). */
export const ENGINE_URLS = {
  wasmUrl: "/chamber_ffi.wasm",
  assetUrl: "/chamber.chamber",
  workletUrl: "/chamber-worklet.js",
};
