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

/// Top-down radar mirroring the web prototype: agents on a front arc, the listener's
/// facing cone (fades when looking down), done-state gold rings + ping ripples.
struct Radar: View {
    @ObservedObject var engine: ChamberEngine

    var body: some View {
        Canvas { ctx, size in
            let cx = size.width / 2, cy = size.height / 2
            let R = min(size.width, size.height) * 0.36
            let dim = 0.4 + 0.6 * engine.lookGatePub

            // ambient rings
            for i in 1...3 {
                let r = R * Double(i) / 3
                ctx.stroke(Path(ellipseIn: CGRect(x: cx - r, y: cy - r, width: 2 * r, height: 2 * r)),
                           with: .color(.white.opacity(0.05)))
            }

            // facing cone
            var cone = Path()
            cone.move(to: CGPoint(x: cx, y: cy))
            cone.addArc(center: CGPoint(x: cx, y: cy), radius: R * 1.1,
                        startAngle: .degrees(-90 - 26 + deg(engine.orientRad)),
                        endAngle: .degrees(-90 + 26 + deg(engine.orientRad)), clockwise: false)
            cone.closeSubpath()
            ctx.fill(cone, with: .color(Color(hex: "#5fd0c5").opacity(0.16 * dim)))

            // listener
            ctx.fill(Path(ellipseIn: CGRect(x: cx - 4, y: cy - 4, width: 8, height: 8)), with: .color(.white))

            for a in engine.snapshot {
                let ang = a.bearing - .pi / 2
                let x = cx + cos(ang) * R
                let y = cy + sin(ang) * R
                let faced = a.id == engine.facedPub
                let baseR = faced ? 7.0 : 5.0

                if a.state == .done, a.pingAge >= 0, a.pingAge < 0.9 {
                    let age = a.pingAge / 0.9
                    let rr = baseR + age * R * 0.18
                    ctx.stroke(Path(ellipseIn: CGRect(x: x - rr, y: y - rr, width: 2 * rr, height: 2 * rr)),
                               with: .color(Color(hex: "#ffce6b").opacity(0.5 * (1 - age))), lineWidth: 2)
                }

                let dotRect = CGRect(x: x - baseR, y: y - baseR, width: 2 * baseR, height: 2 * baseR)
                let alpha = (a.state == .heard ? 0.4 : (faced ? 1.0 : 0.85)) * dim
                ctx.fill(Path(ellipseIn: dotRect), with: .color(Color(hex: a.hex).opacity(alpha)))

                if a.state == .done {
                    ctx.stroke(Path(ellipseIn: dotRect), with: .color(Color(hex: "#ffce6b")), lineWidth: 2.5)
                } else if a.state == .summarizing {
                    ctx.stroke(Path(ellipseIn: dotRect), with: .color(Color(hex: "#5fd0c5")), lineWidth: 2.5)
                } else if faced {
                    ctx.stroke(Path(ellipseIn: dotRect), with: .color(Color(hex: "#5fd0c5")), lineWidth: 3)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .frame(maxWidth: 460, maxHeight: 460)
        .padding(16)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
