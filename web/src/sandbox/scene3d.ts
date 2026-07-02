// Three.js viewport for the sandbox scene editor: orbitable 3D view with the listener
// head, draggable source spheres, facing arrows (directivity) and extent shells.
// Chamber frame throughout: +x right, +y up, +z back (front = −z). Three.js is the same
// right-handed frame, so no conversion — the camera just starts behind/above the listener.

import * as THREE from "three";
import { OrbitControls } from "three/addons/controls/OrbitControls.js";

/** How far the up/down grip floats above a source's centre (metres). */
const HANDLE_LIFT = 0.3;

export interface SceneSource {
  id: string;
  name: string;
  pos: { x: number; y: number; z: number };
  color: string;
  directivity: number;
  facing: { x: number; y: number; z: number };
  extent: number;
  playing: boolean;
}

interface SourceMeshes {
  ball: THREE.Mesh;
  ring: THREE.Mesh;
  arrow: THREE.ArrowHelper;
  shell: THREE.Mesh;
  handle: THREE.Mesh; // vertical-move grip above the ball (visible when selected)
  label: THREE.Sprite; // always-visible sound name
  labelText: string; // cached so the canvas texture is only redrawn on change
}

export class SceneView {
  onSelect: (id: string | null) => void = () => {};
  onMove: (id: string, pos: { x: number; y: number; z: number }) => void = () => {};
  onAdd: (pos: { x: number; y: number; z: number }) => void = () => {};
  /** Hover feedback for tooltips: source id (or null) + pointer position in client px. */
  onHover: (id: string | null, x: number, y: number) => void = () => {};

  private renderer: THREE.WebGLRenderer;
  private scene = new THREE.Scene();
  private camera: THREE.PerspectiveCamera;
  private controls: OrbitControls;
  private ray = new THREE.Raycaster();
  private ptr = new THREE.Vector2();
  private meshes = new Map<string, SourceMeshes>();
  private head: THREE.Group;
  private dragId: string | null = null;
  private dragMode: "xz" | "y" = "xz";
  private dragPlane = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);
  private dragStartY = 0; // source y at vertical-drag start
  private dragStartHitY = 0; // plane-hit y at vertical-drag start
  private selected: string | null = null;

  constructor(private canvas: HTMLCanvasElement) {
    this.renderer = new THREE.WebGLRenderer({ canvas, antialias: true });
    this.renderer.setPixelRatio(Math.min(devicePixelRatio, 2));
    this.scene.background = new THREE.Color(0x0e1013);
    this.scene.fog = new THREE.Fog(0x0e1013, 14, 30);

    this.camera = new THREE.PerspectiveCamera(55, 1, 0.05, 100);
    this.camera.position.set(0, 3.2, 4.6); // behind/above the listener, looking front (−z)
    this.controls = new OrbitControls(this.camera, canvas);
    this.controls.target.set(0, 0.4, -1.5);
    this.controls.maxPolarAngle = Math.PI * 0.495;
    this.controls.enableDamping = true;

    const grid = new THREE.GridHelper(20, 20, 0x2a3242, 0x1a1f2b);
    this.scene.add(grid);
    this.scene.add(new THREE.AmbientLight(0xffffff, 0.7));
    const key = new THREE.DirectionalLight(0xffffff, 1.4);
    key.position.set(2, 5, 3);
    this.scene.add(key);

    // "front" marker on the floor at −z
    const frontMark = new THREE.Mesh(
      new THREE.ConeGeometry(0.1, 0.3, 12),
      new THREE.MeshBasicMaterial({ color: 0x3a4763 }),
    );
    frontMark.rotation.x = -Math.PI / 2;
    frontMark.position.set(0, 0.01, -4);
    this.scene.add(frontMark);

    this.head = buildHead();
    this.scene.add(this.head);

    canvas.addEventListener("pointerdown", this.onPointerDown);
    canvas.addEventListener("pointermove", this.onPointerMove);
    canvas.addEventListener("pointerup", this.onPointerUp);
    canvas.addEventListener("dblclick", this.onDblClick);

    const resize = () => {
      const w = canvas.clientWidth, h = canvas.clientHeight;
      if (w === 0 || h === 0) return;
      this.renderer.setSize(w, h, false);
      this.camera.aspect = w / h;
      this.camera.updateProjectionMatrix();
    };
    new ResizeObserver(resize).observe(canvas);
    resize();

    const tick = () => {
      this.controls.update();
      this.renderer.render(this.scene, this.camera);
      requestAnimationFrame(tick);
    };
    tick();
  }

  /** Client-pixel position of a source's ball (and its up/down handle) — for tests/tooling. */
  screenPos(id: string): { x: number; y: number; hx: number; hy: number } | null {
    const m = this.meshes.get(id);
    if (!m) return null;
    const r = this.canvas.getBoundingClientRect();
    const proj = (v: THREE.Vector3) => {
      const p = v.clone().project(this.camera);
      return { x: r.left + ((p.x + 1) / 2) * r.width, y: r.top + ((1 - p.y) / 2) * r.height };
    };
    const b = proj(m.ball.position);
    const h = proj(m.handle.position);
    return { x: b.x, y: b.y, hx: h.x, hy: h.y };
  }

  /** Update the listener head pose (position in metres, yaw in degrees, front = −z at 0°). */
  setHead(pos: { x: number; y: number; z: number }, yawDeg: number): void {
    this.head.position.set(pos.x, pos.y + 0.35, pos.z); // head sits ~ear height above origin marker
    this.head.rotation.y = (-yawDeg * Math.PI) / 180; // yaw>0 turns toward +x (right)
  }

  setSelected(id: string | null): void {
    this.selected = id;
    for (const [sid, m] of this.meshes) {
      m.ring.visible = sid === id;
      m.handle.visible = sid === id;
    }
  }

  /** Reconcile meshes with the source list (create/update/remove). */
  sync(sources: SceneSource[]): void {
    const seen = new Set<string>();
    for (const s of sources) {
      seen.add(s.id);
      let m = this.meshes.get(s.id);
      if (!m) {
        m = this.buildSource(s.color);
        this.meshes.set(s.id, m);
      }
      m.ball.position.set(s.pos.x, s.pos.y, s.pos.z);
      (m.ball.material as THREE.MeshStandardMaterial).color.set(s.color);
      (m.ball.material as THREE.MeshStandardMaterial).emissive.set(s.playing ? s.color : "#000000");
      (m.ball.material as THREE.MeshStandardMaterial).emissiveIntensity = s.playing ? 0.35 : 0;
      m.ring.position.copy(m.ball.position);
      m.ring.visible = s.id === this.selected;
      m.handle.position.copy(m.ball.position).y += HANDLE_LIFT;
      m.handle.visible = s.id === this.selected;
      (m.handle.material as THREE.MeshBasicMaterial).color.set(s.color);
      // name label rides just above the ball (higher when the handle is out)
      m.label.position.copy(m.ball.position).y += s.id === this.selected ? HANDLE_LIFT + 0.18 : 0.24;
      if (m.labelText !== s.name) {
        m.labelText = s.name;
        drawLabel(m.label, s.name, s.color);
      }
      // facing arrow only when the source is directional
      const f = new THREE.Vector3(s.facing.x, s.facing.y, s.facing.z);
      const showArrow = s.directivity > 0.001 && f.lengthSq() > 1e-9;
      m.arrow.visible = showArrow;
      if (showArrow) {
        m.arrow.position.copy(m.ball.position);
        m.arrow.setDirection(f.normalize());
        m.arrow.setLength(0.45 + 0.45 * s.directivity, 0.16, 0.09);
      }
      // extent shell
      m.shell.visible = s.extent > 0.001;
      if (m.shell.visible) {
        m.shell.position.copy(m.ball.position);
        m.shell.scale.setScalar(Math.max(0.001, s.extent));
      }
    }
    for (const [id, m] of this.meshes) {
      if (!seen.has(id)) {
        this.scene.remove(m.ball, m.ring, m.arrow, m.shell, m.handle, m.label);
        this.meshes.delete(id);
      }
    }
  }

  private buildSource(color: string): SourceMeshes {
    const ball = new THREE.Mesh(
      new THREE.SphereGeometry(0.12, 24, 16),
      new THREE.MeshStandardMaterial({ color, roughness: 0.4 }),
    );
    const ring = new THREE.Mesh(
      new THREE.TorusGeometry(0.22, 0.012, 8, 40),
      new THREE.MeshBasicMaterial({ color: 0xffffff }),
    );
    ring.rotation.x = Math.PI / 2;
    ring.visible = false;
    const arrow = new THREE.ArrowHelper(new THREE.Vector3(0, 0, -1), undefined, 0.6, new THREE.Color(color).getHex(), 0.16, 0.09);
    arrow.visible = false;
    const shell = new THREE.Mesh(
      new THREE.SphereGeometry(1, 28, 20),
      new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.12, depthWrite: false }),
    );
    shell.visible = false;
    // up/down grip: a small octahedron floating above the ball, rendered on top
    const handle = new THREE.Mesh(
      new THREE.OctahedronGeometry(0.07),
      new THREE.MeshBasicMaterial({ color, transparent: true, opacity: 0.9, depthTest: false }),
    );
    handle.renderOrder = 2;
    handle.visible = false;
    const label = new THREE.Sprite(
      new THREE.SpriteMaterial({ transparent: true, depthTest: false, sizeAttenuation: true }),
    );
    label.renderOrder = 3;
    this.scene.add(ball, ring, arrow, shell, handle, label);
    return { ball, ring, arrow, shell, handle, label, labelText: "" };
  }

  private pick(e: PointerEvent | MouseEvent): { id: string; part: "ball" | "handle" } | null {
    this.setPointer(e);
    this.ray.setFromCamera(this.ptr, this.camera);
    const entries = [...this.meshes.entries()];
    // the selected source's up/down grip wins over anything behind it
    const handles = entries.filter(([, m]) => m.handle.visible);
    const hHits = this.ray.intersectObjects(handles.map(([, m]) => m.handle));
    if (hHits.length) {
      for (const [id, m] of handles) if (m.handle === hHits[0].object) return { id, part: "handle" };
    }
    const hits = this.ray.intersectObjects(entries.map(([, m]) => m.ball));
    if (!hits.length) return null;
    for (const [id, m] of entries) if (m.ball === hits[0].object) return { id, part: "ball" };
    return null;
  }

  private setPointer(e: PointerEvent | MouseEvent): void {
    const r = this.canvas.getBoundingClientRect();
    this.ptr.set(((e.clientX - r.left) / r.width) * 2 - 1, -((e.clientY - r.top) / r.height) * 2 + 1);
  }

  private onPointerDown = (e: PointerEvent): void => {
    if (e.button !== 0) return;
    const hit = this.pick(e);
    this.onSelect(hit?.id ?? null);
    if (!hit) return;
    this.dragId = hit.id;
    this.onHover(null, 0, 0); // tooltip off while dragging
    const m = this.meshes.get(hit.id)!;
    if (hit.part === "handle") {
      // vertical drag: a camera-facing plane through the source keeps the ray↔plane
      // intersection well-conditioned at any view angle; move by the y-delta of the hit.
      this.dragMode = "y";
      const n = this.camera.position.clone().sub(m.ball.position);
      n.y = 0;
      if (n.lengthSq() < 1e-9) n.set(0, 0, 1);
      n.normalize();
      this.dragPlane.setFromNormalAndCoplanarPoint(n, m.ball.position);
      this.dragStartY = m.ball.position.y;
      const p = new THREE.Vector3();
      this.ray.setFromCamera(this.ptr, this.camera);
      this.dragStartHitY = this.ray.ray.intersectPlane(this.dragPlane, p) ? p.y : m.ball.position.y;
    } else {
      this.dragMode = "xz";
      this.dragPlane.set(new THREE.Vector3(0, 1, 0), -m.ball.position.y); // drag in the source's XZ plane
    }
    this.controls.enabled = false;
    this.canvas.setPointerCapture(e.pointerId);
  };

  private onPointerMove = (e: PointerEvent): void => {
    if (!this.dragId) {
      // hover feedback: tooltip + cursor hint
      const hit = this.pick(e);
      this.canvas.style.cursor = hit ? (hit.part === "handle" ? "ns-resize" : "grab") : "";
      this.onHover(hit?.id ?? null, e.clientX, e.clientY);
      return;
    }
    this.setPointer(e);
    this.ray.setFromCamera(this.ptr, this.camera);
    const p = new THREE.Vector3();
    if (!this.ray.ray.intersectPlane(this.dragPlane, p)) return;
    const m = this.meshes.get(this.dragId)!;
    if (this.dragMode === "y") {
      const y = Math.max(-2, Math.min(2.5, this.dragStartY + (p.y - this.dragStartHitY)));
      this.onMove(this.dragId, { x: m.ball.position.x, y, z: m.ball.position.z });
    } else {
      const clamp = (v: number) => Math.max(-9.5, Math.min(9.5, v));
      this.onMove(this.dragId, { x: clamp(p.x), y: -this.dragPlane.constant, z: clamp(p.z) });
    }
  };

  private onPointerUp = (): void => {
    this.dragId = null;
    this.controls.enabled = true;
  };

  private onDblClick = (e: MouseEvent): void => {
    if (this.pick(e)) return; // double-clicking a source shouldn't spawn another
    this.setPointer(e);
    this.ray.setFromCamera(this.ptr, this.camera);
    const ground = new THREE.Plane(new THREE.Vector3(0, 1, 0), 0);
    const p = new THREE.Vector3();
    if (this.ray.ray.intersectPlane(ground, p)) this.onAdd({ x: p.x, y: 0, z: p.z });
  };
}

/** Redraw a sprite's canvas texture with the sound name (pill on a dark ground). */
function drawLabel(sprite: THREE.Sprite, text: string, color: string): void {
  const shown = text.length > 22 ? text.slice(0, 21) + "…" : text;
  const px = 26; // font size in canvas px
  const canvas = document.createElement("canvas");
  const g = canvas.getContext("2d")!;
  g.font = `600 ${px}px -apple-system, "Segoe UI", sans-serif`;
  const w = Math.ceil(g.measureText(shown).width) + 26;
  const h = px + 18;
  canvas.width = w * 2; // 2x for crispness
  canvas.height = h * 2;
  g.scale(2, 2);
  g.font = `600 ${px}px -apple-system, "Segoe UI", sans-serif`;
  g.fillStyle = "rgba(14,16,19,0.78)";
  g.beginPath();
  g.roundRect(0, 0, w, h, 9);
  g.fill();
  g.fillStyle = color;
  g.textBaseline = "middle";
  g.fillText(shown, 13, h / 2 + 1);
  const tex = new THREE.CanvasTexture(canvas);
  tex.colorSpace = THREE.SRGBColorSpace;
  sprite.material.map?.dispose();
  sprite.material.map = tex;
  sprite.material.needsUpdate = true;
  // world size: fixed height, width follows the text's aspect
  const worldH = 0.16;
  sprite.scale.set((w / h) * worldH, worldH, 1);
}

/** Listener head: sphere + nose cone + ear nubs, teal like the old harness. */
function buildHead(): THREE.Group {
  const g = new THREE.Group();
  const mat = new THREE.MeshStandardMaterial({ color: 0x5fd0c5, roughness: 0.5 });
  const skull = new THREE.Mesh(new THREE.SphereGeometry(0.11, 24, 16), mat);
  const nose = new THREE.Mesh(new THREE.ConeGeometry(0.035, 0.09, 12), mat);
  nose.position.set(0, 0, -0.13); // front = −z
  nose.rotation.x = -Math.PI / 2;
  const earL = new THREE.Mesh(new THREE.SphereGeometry(0.028, 10, 8), mat);
  earL.position.set(-0.11, 0, 0);
  const earR = earL.clone();
  earR.position.set(0.11, 0, 0);
  const stand = new THREE.Mesh(
    new THREE.CylinderGeometry(0.006, 0.006, 0.35),
    new THREE.MeshBasicMaterial({ color: 0x2a3242 }),
  );
  stand.position.y = -0.18;
  g.add(skull, nose, earL, earR, stand);
  return g;
}
