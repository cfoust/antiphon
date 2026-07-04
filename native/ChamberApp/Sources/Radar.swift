import SwiftUI

extension Color {
    init(hex: String) {
        let s = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self = Color(.sRGB,
                     red: Double((v >> 16) & 0xFF) / 255,
                     green: Double((v >> 8) & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }
}

/// Full-bleed top-down chamber. Agents are world-anchored dots you can pick up
/// and drag anywhere in 2D — the engine follows live (with the audition pulse),
/// so you *hear* the dot move. The listener slides within the rings from head
/// translation; the facing cone tracks head yaw.
struct RadarView: View {
    @ObservedObject var engine: ChamberEngine
    @State private var dragging = -1
    @State private var dragMissed = false

    /// px-per-metre chosen so the default 1.3 m arc sits well inside the window.
    private func scale(_ size: CGSize) -> CGFloat {
        min(size.width, size.height) * 0.34 / 1.3
    }

    private func toScreen(_ x: Double, _ z: Double, _ size: CGSize) -> CGPoint {
        let s = scale(size)
        return CGPoint(x: size.width / 2 + CGFloat(x) * s,
                       y: size.height / 2 + CGFloat(z) * s)
    }

    private func toWorld(_ p: CGPoint, _ size: CGSize) -> (x: Double, z: Double) {
        let s = scale(size)
        return (Double((p.x - size.width / 2) / s), Double((p.y - size.height / 2) / s))
    }

    private func hitTest(_ p: CGPoint, _ size: CGSize) -> Int? {
        var best: Int? = nil
        var bd: CGFloat = 26 // generous grab radius
        for a in engine.snapshot {
            let q = toScreen(a.x, a.z, size)
            let d = hypot(q.x - p.x, q.y - p.y)
            if d < bd { bd = d; best = a.id }
        }
        return best
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            Canvas { ctx, size in
                let cx = size.width / 2, cy = size.height / 2
                let s = scale(size)
                let dim = 0.4 + 0.6 * engine.lookGatePub
                // asleep: everything recedes into the gray
                let muted = !engine.watching
                let mul = muted ? 0.45 : 1.0
                func ring(_ r: CGFloat, at p: CGPoint, alpha: Double, width: CGFloat = 1) {
                    ctx.stroke(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                               with: .color(.white.opacity(alpha * mul)), lineWidth: width)
                }

                // listener slides with head translation, world-anchored dots stay put
                let hp = engine.headPos
                let lim = CGFloat(1.0) * s
                let lcx = cx + max(-lim, min(lim, CGFloat(hp.x) * s))
                let lcy = cy + max(-lim, min(lim, CGFloat(hp.z) * s))
                let c = CGPoint(x: cx, y: cy)

                // The Antiphon eye, monochrome: inner disc, thick iris band, a
                // bold ring, then hairline outer rings. World-anchored on the
                // calibrated neutral — the pupil (you) drifts inside it.
                // kept just above the threshold of noticing — texture, not a boundary
                ctx.fill(Path(ellipseIn: CGRect(x: cx - 0.5 * s, y: cy - 0.5 * s, width: s, height: s)),
                         with: .color(.white.opacity(0.02 * mul)))
                ring(0.72 * s, at: c, alpha: 0.03, width: 0.26 * s) // the iris band
                ring(0.95 * s, at: c, alpha: 0.07, width: 1.5)      // the bold ring
                ring(1.30 * s, at: c, alpha: 0.03)                  // hairline, agents' arc
                ring(1.62 * s, at: c, alpha: 0.022)                 // outermost hairline

                // facing cone (only while watching — the pose is frozen asleep)
                if !muted {
                    var cone = Path()
                    cone.move(to: CGPoint(x: lcx, y: lcy))
                    cone.addArc(center: CGPoint(x: lcx, y: lcy), radius: s * 1.3 * 1.15,
                                startAngle: .degrees(-90 - 26 + deg(engine.orientRad)),
                                endAngle: .degrees(-90 + 26 + deg(engine.orientRad)), clockwise: false)
                    cone.closeSubpath()
                    ctx.fill(cone, with: .color(Color(hex: "#5fd0c5").opacity(0.13 * dim)))
                }

                // the pupil: you, glint and all
                let pr: CGFloat = 9
                ctx.fill(Path(ellipseIn: CGRect(x: lcx - pr, y: lcy - pr, width: 2 * pr, height: 2 * pr)),
                         with: .color(.white.opacity(muted ? 0.5 : 1)))
                ctx.fill(Path(ellipseIn: CGRect(x: lcx - pr * 0.42 - 2.4, y: lcy - pr * 0.42 - 2.4,
                                                width: 4.8, height: 4.8)),
                         with: .color(engine.watching
                            ? Color(red: 0.04, green: 0.047, blue: 0.063)
                            : Color(white: 0.18)))

                for a in engine.snapshot {
                    let p = toScreen(a.x, a.z, size)
                    let faced = a.id == engine.facedPub
                    let hovered = a.id == engine.hoveredSeat
                    let dragged = a.id == dragging
                    let baseR: CGFloat = dragged ? 11 : (faced || hovered ? 9 : 7)

                    if a.state == .done, a.pingAge >= 0, a.pingAge < 0.9 {
                        let age = a.pingAge / 0.9
                        let rr = baseR + CGFloat(age) * s * 1.3 * 0.18
                        ctx.stroke(Path(ellipseIn: CGRect(x: p.x - rr, y: p.y - rr, width: 2 * rr, height: 2 * rr)),
                                   with: .color(Color(hex: "#ffce6b").opacity(0.5 * (1 - age))), lineWidth: 2)
                    }

                    // hover halo: the sidebar row under the cursor shows itself here
                    if hovered || dragged {
                        let hr = baseR + 7
                        ctx.fill(Path(ellipseIn: CGRect(x: p.x - hr, y: p.y - hr, width: 2 * hr, height: 2 * hr)),
                                 with: .color(Color(hex: a.hex).opacity(0.22)))
                    }

                    let dotRect = CGRect(x: p.x - baseR, y: p.y - baseR, width: 2 * baseR, height: 2 * baseR)
                    let alpha = (a.state == .heard ? 0.4 : (faced ? 1.0 : 0.85)) * dim * mul
                    ctx.fill(Path(ellipseIn: dotRect), with: .color(Color(hex: a.hex).opacity(alpha)))

                    if a.state == .done {
                        ctx.stroke(Path(ellipseIn: dotRect), with: .color(Color(hex: "#ffce6b")), lineWidth: 2.5)
                    } else if a.state == .summarizing {
                        ctx.stroke(Path(ellipseIn: dotRect), with: .color(Color(hex: "#5fd0c5")), lineWidth: 2.5)
                    } else if faced {
                        ctx.stroke(Path(ellipseIn: dotRect), with: .color(Color(hex: "#5fd0c5")), lineWidth: 3)
                    }
                    if hovered || dragged {
                        ctx.stroke(Path(ellipseIn: dotRect), with: .color(.white.opacity(0.85)), lineWidth: 1.5)
                    }
                }
            }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in
                        if dragging < 0 && !dragMissed {
                            if let hit = hitTest(v.startLocation, size) {
                                dragging = hit
                                engine.dragBegan(hit)
                            } else {
                                dragMissed = true // empty press: don't grab dots on the way
                            }
                        }
                        guard dragging >= 0 else { return }
                        let w = toWorld(v.location, size)
                        engine.dragMoved(dragging, x: w.x, z: w.z)
                    }
                    .onEnded { _ in
                        if dragging >= 0 { engine.dragEnded() }
                        dragging = -1
                        dragMissed = false
                    }
            )
        }
    }
}
