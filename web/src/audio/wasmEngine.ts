// WasmEngine — loads the Rust binaural engine (chamber-ffi) into an AudioWorklet and
// exposes a small, host-friendly API. This is the shared spatializer for the Chamber app
// and the test harness, and is the web half of "native + web, identical engine".

export interface Vec3 { x: number; y: number; z: number; }
export interface Quat { w: number; x: number; y: number; z: number; }

/** Room geometry as placed by the engine: x/z-centred on the origin (the listener's
 *  nominal ear position), floor at `y = -earHeight`, ceiling at `y = h - earHeight`. */
export interface RoomDims { w: number; h: number; d: number; earHeight: number; }

export interface SourceOpts {
  samples?: Float32Array; // mono signal (48 kHz assumed by the asset)
  gain?: number;
  pos?: Vec3;
  send?: number; // reverb send 0..1
  /** World-space emission axis; {0,0,0} (default) = omnidirectional. */
  facing?: Vec3;
  /** Radiation-pattern amount 0..1 (0 = omni, 1 = cardioid-like; HF beams harder). */
  directivity?: number;
  /** Source radius in metres (0 = point source). */
  extent?: number;
  loop?: boolean;
  play?: boolean;
}

export class WasmEngine {
  node!: AudioWorkletNode;
  numRooms = 0;
  private ctx: AudioContext;
  private ready: Promise<void>;
  private resolveReady!: () => void;
  // pending roomDims queries, FIFO per room index
  private dimsWaiters = new Map<number, ((d: RoomDims | null) => void)[]>();

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
      } else if (ev.data?.type === "roomDims") {
        const waiter = e.dimsWaiters.get(ev.data.index)?.shift();
        const d = ev.data.dims as number[] | null;
        waiter?.(d ? { w: d[0], h: d[1], d: d[2], earHeight: d[3] } : null);
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

  /** Position/gain/send (+ optional directivity/extent) for a live-input source slot. */
  setInputCfg(
    i: number,
    cfg: { pos: Vec3; gain?: number; send?: number; facing?: Vec3; directivity?: number; extent?: number },
  ): void {
    this.node.port.postMessage({
      type: "inputCfg", index: i,
      x: cfg.pos.x, y: cfg.pos.y, z: cfg.pos.z, gain: cfg.gain ?? 1, send: cfg.send ?? 0.3,
      fx: cfg.facing?.x ?? 0, fy: cfg.facing?.y ?? 0, fz: cfg.facing?.z ?? 0,
      directivity: cfg.directivity ?? 0, extent: cfg.extent ?? 0,
    });
  }

  /** Add or update a source. `samples` (transferable) replaces its buffer. */
  setSource(id: string, o: SourceOpts): void {
    const msg: Record<string, unknown> = { type: "src", id };
    if (o.samples) msg.samples = o.samples;
    if (o.gain !== undefined) msg.gain = o.gain;
    if (o.pos) { msg.x = o.pos.x; msg.y = o.pos.y; msg.z = o.pos.z; }
    if (o.send !== undefined) msg.send = o.send;
    if (o.facing) { msg.fx = o.facing.x; msg.fy = o.facing.y; msg.fz = o.facing.z; }
    if (o.directivity !== undefined) msg.directivity = o.directivity;
    if (o.extent !== undefined) msg.extent = o.extent;
    if (o.loop !== undefined) msg.loop = o.loop;
    if (o.play !== undefined) msg.play = o.play;
    const transfer = o.samples ? [o.samples.buffer] : [];
    this.node.port.postMessage(msg, transfer);
  }

  /** Re-trigger a one-shot source from the start. */
  trigger(id: string): void { this.node.port.postMessage({ type: "src", id, play: true }); }
  /** Stop a source (keeps its buffer/params; `trigger` restarts it). */
  stopSource(id: string): void { this.node.port.postMessage({ type: "src", id, stop: true }); }
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
  /** "An agent is waiting" cue: number of waiting agents (0 = silent). Voices per pulse = n. */
  setAttentionAgents(n: number): void { this.node.port.postMessage({ type: "attnAgents", n }); }
  /** Minutes over which the attention cue builds from silent → full urgency (louder + faster). */
  setAttentionBuildMinutes(minutes: number): void { this.node.port.postMessage({ type: "attnBuild", minutes }); }
  /** Immersion (eyes) fade target 0..1 (1 = eyes-closed/scene full & cue silent, 0 = eyes-open/scene
   *  silent & cue audible). Applied per-source in-engine; the scene↔cue crossfade is automatic. */
  setImmersionEngine(target: number): void { this.node.port.postMessage({ type: "immersion", value: target }); }
  setRoom(index: number): void { this.node.port.postMessage({ type: "room", index }); }
  /** Geometry of room preset `index` (dims + ear height), or null if out of range. */
  roomDims(index: number): Promise<RoomDims | null> {
    return new Promise((resolve) => {
      const list = this.dimsWaiters.get(index) ?? [];
      list.push(resolve);
      this.dimsWaiters.set(index, list);
      this.node.port.postMessage({ type: "roomDims", index });
    });
  }
  /** Late-tail blend for BRIR rooms: 0 = pure parametric FDN, 1 = pure measured BRIR. */
  setReverbBlend(value: number): void { this.node.port.postMessage({ type: "reverbBlend", value }); }
  setReflections(on: boolean): void { this.node.port.postMessage({ type: "reflections", on }); }
  setMaster(gain: number): void { this.node.port.postMessage({ type: "master", gain }); }
}

/** Default asset/wasm URLs (staged into public/ by tools/build-web.sh). */
export const ENGINE_URLS = {
  wasmUrl: "/chamber_ffi.wasm",
  assetUrl: "/chamber.chamber",
  workletUrl: "/chamber-worklet.js",
};
