import type { Chamber } from "../audio/engine";
import { rad, TAU } from "../math";

/**
 * Abstract top-down radar, sized to fill the (square) viewport. Agents are
 * colored dots on a ring — no names. Orientation comes entirely from head
 * tracking (calibrated), so there are no pointer controls.
 */
export function initRadar(engine: Chamber, cv: HTMLCanvasElement): void {
  const g = cv.getContext("2d")!;

  function resize() {
    const dpr = Math.min(window.devicePixelRatio || 1, 2);
    const size = Math.min(window.innerWidth, window.innerHeight);
    cv.style.width = size + "px";
    cv.style.height = size + "px";
    cv.width = Math.floor(size * dpr);
    cv.height = Math.floor(size * dpr);
  }
  window.addEventListener("resize", resize);
  resize();

  function draw() {
    engine.tick();
    const W = cv.width,
      H = cv.height,
      cx = W / 2,
      cy = H / 2,
      R = Math.min(W, H) * 0.34;
    g.clearRect(0, 0, W, H);

    // ambient rings
    for (let i = 1; i <= 3; i++) {
      g.beginPath();
      g.arc(cx, cy, (R * i) / 3, 0, TAU);
      g.strokeStyle = "rgba(255,255,255,0.04)";
      g.lineWidth = 1;
      g.stroke();
    }

    // facing cone (fades as you look down)
    g.save();
    g.translate(cx, cy);
    g.rotate(engine.orient);
    const grad = g.createLinearGradient(0, 0, 0, -R * 1.15);
    grad.addColorStop(0, "rgba(95,208,197," + 0.22 * engine.lookGate + ")");
    grad.addColorStop(1, "rgba(95,208,197,0)");
    g.beginPath();
    g.moveTo(0, 0);
    g.arc(0, 0, R * 1.12, -Math.PI / 2 - rad(26), -Math.PI / 2 + rad(26));
    g.closePath();
    g.fillStyle = grad;
    g.fill();
    g.restore();

    // listener head
    g.save();
    g.translate(cx, cy);
    g.rotate(engine.orient);
    g.fillStyle = "#e7ecf3";
    g.beginPath();
    g.arc(0, 0, R * 0.05, 0, TAU);
    g.fill();
    g.fillStyle = "#0a0c10";
    const n = R * 0.05;
    g.beginPath();
    g.moveTo(0, -n);
    g.lineTo(-n * 0.45, -n * 0.4);
    g.lineTo(n * 0.45, -n * 0.4);
    g.closePath();
    g.fill();
    g.restore();

    const bs = engine.bearings();
    const fa = engine.facedAgent();
    const now = performance.now(),
      tt = now / 1000;
    // overall dimming when looking down (everyone whispering)
    const dim = 0.4 + 0.6 * engine.lookGate;

    for (let i = 0; i < engine.activeCount; i++) {
      const a = engine.agents[i];
      const N = engine.nodes[a.id];
      const st = N ? N.state : "working";
      const ang = bs[i] - Math.PI / 2;
      const x = cx + Math.cos(ang) * R,
        y = cy + Math.sin(ang) * R;
      const isFront = !!fa && fa.id === a.id;
      const baseR = R * (isFront ? 0.07 : 0.05);

      // ping ripples (done)
      if (N && st === "done" && N.lastPingMs) {
        const age = (now - N.lastPingMs) / 900;
        if (age >= 0 && age <= 1) {
          g.beginPath();
          g.arc(x, y, baseR + age * R * 0.18, 0, TAU);
          g.strokeStyle = "rgba(255,206,107," + 0.5 * (1 - age) + ")";
          g.lineWidth = 2;
          g.stroke();
        }
      }
      // focus-enter flash
      if (N && N.focusFlash) {
        const fage = (now - N.focusFlash) / 500;
        if (fage >= 0 && fage <= 1) {
          const col = st === "done" ? "255,206,107" : "95,208,197";
          g.beginPath();
          g.arc(x, y, baseR + R * 0.03 + fage * R * 0.2, 0, TAU);
          g.strokeStyle = "rgba(" + col + "," + 0.85 * (1 - fage) + ")";
          g.lineWidth = 3;
          g.stroke();
        }
      }

      // ambient halo
      const fast = st === "done" ? 5 : st === "summarizing" ? 3 : 2.2;
      const pulse = 1 + 0.22 * Math.sin(tt * fast + i);
      if (st !== "heard") {
        g.beginPath();
        g.arc(x, y, baseR * pulse + (st === "done" ? R * 0.035 : R * 0.018), 0, TAU);
        const halo = st === "done" ? "255,206,107" : "255,255,255";
        g.fillStyle = "rgba(" + halo + "," + (st === "done" ? 0.14 : 0.06) * dim + ")";
        g.fill();
      }

      // body dot
      g.globalAlpha = (st === "heard" ? 0.4 : isFront ? 1 : 0.85) * dim;
      g.beginPath();
      g.arc(x, y, baseR, 0, TAU);
      g.fillStyle = a.color;
      g.fill();
      g.globalAlpha = 1;
      if (st === "done") {
        g.lineWidth = 2.5;
        g.strokeStyle = "#ffce6b";
        g.stroke();
      } else if (st === "summarizing") {
        g.lineWidth = 2.5;
        g.strokeStyle = "#5fd0c5";
        g.stroke();
      } else if (isFront) {
        g.lineWidth = 3;
        g.strokeStyle = "#5fd0c5";
        g.stroke();
      }

      // radio-static specks when you look at a heard agent
      if (N && st === "heard" && isFront) {
        g.strokeStyle = "rgba(154,166,184,0.5)";
        g.lineWidth = 1;
        for (let s = 0; s < 10; s++) {
          const a2 = Math.random() * TAU,
            rr = baseR + R * (0.008 + Math.random() * 0.06);
          const sx = x + Math.cos(a2) * rr,
            sy = y + Math.sin(a2) * rr;
          g.beginPath();
          g.moveTo(sx, sy);
          g.lineTo(sx + Math.random() * 3 - 1.5, sy + Math.random() * 3 - 1.5);
          g.stroke();
        }
      }
    }
    requestAnimationFrame(draw);
  }
  requestAnimationFrame(draw);
}
