import SwiftUI

// The right rail: everyone in the room, at a glance. Hovering a row lights the
// agent up on the radar; snoozing sends it to the bottom of the list and out
// of the world (silent + invisible) while its updates keep accumulating.

struct AgentSidebar: View {
    @ObservedObject var engine: AntiphonEngine
    @ObservedObject private var i18n = I18n.shared
    @AppStorage("sidebar.width") private var width = 300.0
    @State private var dragStartWidth: Double?
    static let widthRange = 240.0...420.0

    var body: some View {
        let rows = engine.agentList
        let active = rows.filter { !$0.snoozed }
        let snoozed = rows.filter { $0.snoozed }

        VStack(alignment: .leading, spacing: 0) {
            Text(L("IN THE ROOM"))
                .font(.caption2.weight(.semibold))
                .kerning(1.2)
                .foregroundStyle(.white.opacity(0.35))
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 8)

            if rows.isEmpty {
                Text(engine.bridged
                    ? L("No agents yet — sessions appear here as they join.")
                    : L("Waiting for antiphond — running the canned demo."))
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.4))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    // Plain VStack on purpose: LazyVStack cached row views across
                    // the two ForEach blocks (same seat ids), so a row moved to
                    // the snoozed section kept its stale vm — its moon then kept
                    // calling "snooze" instead of "wake". Handfuls of rows don't
                    // need laziness; the per-row .id below forces a remount when
                    // a row changes sections.
                    VStack(spacing: 4) {
                        ForEach(active) { vm in row(vm) }
                        if !snoozed.isEmpty {
                            HStack(spacing: 8) {
                                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                                Text(L("SNOOZED"))
                                    .font(.system(size: 9, weight: .semibold))
                                    .kerning(1.1)
                                    .foregroundStyle(.white.opacity(0.3))
                                Rectangle().fill(.white.opacity(0.1)).frame(height: 1)
                            }
                            .padding(.vertical, 6)
                            .padding(.horizontal, 4)
                            ForEach(snoozed) { vm in row(vm) }
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(width: width)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.07)))
        // the rail's edge is draggable: a slim, invisible grip
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(.clear)
                .frame(width: 9)
                .contentShape(Rectangle())
                .onHover { over in (over ? NSCursor.resizeLeftRight : NSCursor.arrow).set() }
                .gesture(
                    DragGesture(minimumDistance: 1)
                        .onChanged { v in
                            let start = dragStartWidth ?? width
                            dragStartWidth = start
                            width = (start - v.translation.width)
                                .clamped(to: AgentSidebar.widthRange)
                        }
                        .onEnded { _ in dragStartWidth = nil }
                )
        }
        .fontDesign(.rounded)
    }

    private func row(_ vm: AgentListVM) -> some View {
        AgentRowView(vm: vm,
                     spotlit: engine.hoveredSeat == vm.id && !vm.snoozed,
                     onHover: { over in engine.setHovered(over ? vm.id : -1) },
                     onSnooze: { engine.setSnoozed(vm.id, !vm.snoozed) })
            // section membership is part of the view's identity — moving between
            // active/snoozed must rebuild the row (fresh vm, fresh closures)
            .id("\(vm.id)-\(vm.snoozed ? "z" : "a")")
    }
}

private struct AgentRowView: View {
    let vm: AgentListVM
    let spotlit: Bool // the radar's hover, mirrored back into the list
    let onHover: (Bool) -> Void
    let onSnooze: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            // the identity dot carries status: glow = working, gold ring =
            // waiting for you, dim = idle/resting — no words needed
            Circle()
                .fill(Color(hex: vm.hex).opacity(dotOpacity))
                .frame(width: 9, height: 9)
                .shadow(color: dotGlow, radius: 4.5)
                .overlay {
                    if vm.waiting {
                        Circle().stroke(Color(hex: "#ffce6b"), lineWidth: 1.8)
                            .frame(width: 15, height: 15)
                    }
                }
                .padding(.top, 4)

            // C · title + chips: the title owns the row; one scannable chip
            // line (status · branch · folder); the last words appear only when
            // the agent is waiting/reporting — that's when they matter
            VStack(alignment: .leading, spacing: 3.5) {
                Text(vm.title.isEmpty ? (vm.name.isEmpty ? "—" : vm.name) : vm.title)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.white.opacity(vm.snoozed ? 0.45 : 0.92))
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if !vm.snoozed {
                    if showPreview {
                        Text(vm.lastLine)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }
                    HStack(spacing: 5) {
                        chip(LStatus(vm.status), fg: statusColor,
                             bg: statusColor.opacity(vm.status == "idle" || vm.status == "resting" ? 0.07 : 0.16))
                        if !vm.branch.isEmpty {
                            chip("⎇ \(vm.branch)", fg: Color(hex: "#93a7ee"),
                                 bg: Color(hex: "#7d93e8").opacity(0.13))
                        }
                        if !vm.cwd.isEmpty {
                            chip(shortDir, fg: .white.opacity(0.5), bg: .white.opacity(0.07))
                        }
                    }
                    .clipped()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if hovering || vm.snoozed {
                Button(action: onSnooze) {
                    Image(systemName: vm.snoozed ? "moon.zzz.fill" : "moon.zzz")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
                .help(vm.snoozed ? L("Wake — back into the room") : L("Snooze — out of the room, keeps updating"))
                .padding(.top, 3)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(hovering || spotlit ? Color.white.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .help(fullContext) // the whole story on hover: kind · repo ⎇ branch · full path
        .onTapGesture {
            if vm.snoozed { onSnooze() } // the whole snoozed row is a wake button
        }
        .onHover { over in
            hovering = over
            if !vm.snoozed { onHover(over) } // snoozed agents aren't in the world
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
    }

    private func chip(_ text: String, fg: Color, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(fg)
            .padding(.horizontal, 6.5).padding(.vertical, 2)
            .background(bg, in: Capsule())
            .lineLimit(1)
    }

    /// The last words matter when the agent wants you (waiting) or is mid-report.
    private var showPreview: Bool {
        !vm.lastLine.isEmpty && (vm.waiting || vm.status == "reporting" || vm.status.hasPrefix("waiting"))
    }

    /// "~/chamber" — just the folder, the full path lives in the tooltip.
    private var shortDir: String {
        let name = (vm.cwd as NSString).lastPathComponent
        return name.isEmpty ? tildePath(vm.cwd) : "~/" + name
    }

    private var dotOpacity: Double {
        if vm.snoozed { return 0.35 }
        return vm.status == "idle" || vm.status == "resting" ? 0.4 : 1
    }

    private var dotGlow: Color {
        if vm.snoozed { return .clear }
        return vm.status == "working" ? Color(hex: vm.hex).opacity(0.85) : .clear
    }

    private var fullContext: String {
        var parts: [String] = []
        if !vm.kind.isEmpty { parts.append(prettyAgentKind(vm.kind)) }
        if !vm.repo.isEmpty { parts.append(vm.branch.isEmpty ? vm.repo : "\(vm.repo) ⎇ \(vm.branch)") }
        else if !vm.branch.isEmpty { parts.append("⎇ \(vm.branch)") }
        if !vm.cwd.isEmpty { parts.append(tildePath(vm.cwd)) }
        return parts.joined(separator: " · ")
    }

    private var statusColor: Color {
        switch vm.status { // locale-independent codes from the engine
        case "working": return Color(hex: "#7D9F77")            // sage — alive
        case "reporting": return Color(hex: "#5fd0c5")
        case let s where s.hasPrefix("waiting"): return Color(hex: "#ffce6b")
        default: return .white.opacity(0.45)                    // idle / resting
        }
    }
}

/// "claude-code" → "Claude Code" (shared with the talk-back panel's chip).
func prettyAgentKind(_ kind: String) -> String {
    kind.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
