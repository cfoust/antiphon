import SwiftUI

// The right rail: everyone in the room, at a glance. Hovering a row lights the
// agent up on the radar; snoozing sends it to the bottom of the list and out
// of the world (silent + invisible) while its updates keep accumulating.

struct AgentSidebar: View {
    @ObservedObject var engine: ChamberEngine
    @ObservedObject private var i18n = I18n.shared

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
                    : L("Waiting for chamberd — running the canned demo."))
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
        .frame(width: 272)
        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.white.opacity(0.07)))
        .fontDesign(.rounded)
    }

    private func row(_ vm: AgentListVM) -> some View {
        AgentRowView(vm: vm,
                     onHover: { over in engine.setHovered(over ? vm.id : -1) },
                     onSnooze: { engine.setSnoozed(vm.id, !vm.snoozed) })
            // section membership is part of the view's identity — moving between
            // active/snoozed must rebuild the row (fresh vm, fresh closures)
            .id("\(vm.id)-\(vm.snoozed ? "z" : "a")")
    }
}

private struct AgentRowView: View {
    let vm: AgentListVM
    let onHover: (Bool) -> Void
    let onSnooze: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(Color(hex: vm.hex).opacity(vm.snoozed ? 0.35 : 1))
                .frame(width: 9, height: 9)
                .shadow(color: vm.snoozed ? .clear : Color(hex: vm.hex).opacity(0.7), radius: 4)
                .padding(.top, 4)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(vm.name.isEmpty ? "—" : vm.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.white.opacity(vm.snoozed ? 0.45 : 0.92))
                    if !vm.kind.isEmpty {
                        Text(prettyAgentKind(vm.kind))
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.45))
                            .padding(.horizontal, 5).padding(.vertical, 1.5)
                            .background(.white.opacity(0.08), in: Capsule())
                    }
                    Spacer(minLength: 0)
                    if vm.waiting {
                        // an unheard summary is waiting — the whole point of the room
                        Circle().fill(Color(hex: "#ffce6b")).frame(width: 7, height: 7)
                            .shadow(color: Color(hex: "#ffce6b").opacity(0.8), radius: 3)
                    }
                }
                if !vm.title.isEmpty {
                    Text(vm.title)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.5))
                        .lineLimit(1)
                }
                HStack(spacing: 5) {
                    Text(LStatus(vm.status))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(statusColor.opacity(vm.snoozed ? 0.5 : 1))
                    if !vm.lastLine.isEmpty {
                        Text("· \(vm.lastLine)")
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.42))
                            .lineLimit(1)
                    }
                }
            }

            // a snoozed row always shows its moon — the way back must never
            // hide behind a hover; active rows reveal theirs on hover
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
        .background(hovering ? Color.white.opacity(0.06) : .clear,
                    in: RoundedRectangle(cornerRadius: 10))
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onTapGesture {
            if vm.snoozed { onSnooze() } // the whole snoozed row is a wake button
        }
        .onHover { over in
            hovering = over
            if !vm.snoozed { onHover(over) } // snoozed agents aren't in the world
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
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
