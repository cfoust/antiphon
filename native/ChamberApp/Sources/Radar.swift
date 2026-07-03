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

                // listener slides with head translation, world-anchored dots stay put
                let hp = engine.headPos
                let lim = CGFloat(1.0) * s
                let lcx = cx + max(-lim, min(lim, CGFloat(hp.x) * s))
                let lcy = cy + max(-lim, min(lim, CGFloat(hp.z) * s))

                // ambient range rings (0.65 / 1.3 / 1.95 m)
                for i in 1...3 {
                    let r = s * 1.3 * CGFloat(i) / 3
                    ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                               with: .color(.white.opacity(0.05)))
                }

                // facing cone (emanates from the listener's current position)
                var cone = Path()
                cone.move(to: CGPoint(x: lcx, y: lcy))
                cone.addArc(center: CGPoint(x: lcx, y: lcy), radius: s * 1.3 * 1.15,
                            startAngle: .degrees(-90 - 26 + deg(engine.orientRad)),
                            endAngle: .degrees(-90 + 26 + deg(engine.orientRad)), clockwise: false)
                cone.closeSubpath()
                ctx.fill(cone, with: .color(Color(hex: "#5fd0c5").opacity(0.13 * dim)))

                // listener
                ctx.fill(Path(ellipseIn: CGRect(x: lcx - 4.5, y: lcy - 4.5, width: 9, height: 9)),
                         with: .color(.white))

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
                    let alpha = (a.state == .heard ? 0.4 : (faced ? 1.0 : 0.85)) * dim
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
