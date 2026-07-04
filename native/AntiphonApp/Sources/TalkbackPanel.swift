import AppKit
import Combine
import SwiftUI

// TalkbackPanel — the talk-back surface (docs/agent-bridge.md, "Talk-back").
//
// A Spotlight-class NSPanel: non-activating, floating, key-without-activating — it
// takes the keyboard the moment the dwell locks (so a dictation tool types into it
// with your eyes still closed) while your editor stays the active app, and dismissing
// it puts the caret back exactly where it was. One face: the letter — header,
// mini-transcript, focused field, keycap footer — summoned while the eyes are still
// closed so it's already the input when they open. (There is deliberately no separate
// eyes-closed visual: the user can't see it.)
//
// Leaving: Enter sends via the hub's say flow; Escape or clicking anywhere else lets
// go; and a check-in costs nothing — with an empty field, the panel dismisses itself
// a few seconds after the eyes open. Text in the field holds it indefinitely.

// MARK: - data

/// One narration line for the mini-transcript (task/progress/blocked/done + text).
struct TalkbackLine: Equatable {
    let kind: String
    let text: String
    let at: TimeInterval
}

/// Per-seat identity from bind frames; survives pre-setup on the engine.
struct TalkbackSeatMeta {
    var agent = "" // registry id — a different id on the same seat is a new tenant
    var name = ""
    var kind = ""
    var title = ""
    var input = "" // reachability: "tmux"/"cy"/"http"/"channel"/"demo", "" = can't hear you
}

/// Everything the panel shows for the locked agent (a value snapshot from the engine).
struct TalkbackAgentInfo {
    let seat: Int
    let name: String
    let colorHex: String
    let kind: String
    let title: String
    let input: String
    let lines: [TalkbackLine]
    var reachable: Bool { !input.isEmpty }
}

final class TalkbackModel: ObservableObject {
    @Published var info: TalkbackAgentInfo?
    @Published var eyesClosed = false
    @Published var draft = ""
}

// MARK: - the panel window

/// Borderless panels refuse key status unless told otherwise; this one's whole job
/// is to become key without activating the app.
final class KeyablePanel: NSPanel {
    var onCancel: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func cancelOperation(_ sender: Any?) { onCancel?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?(); return } // esc even when no field has focus
        super.keyDown(with: event)
    }
}

// MARK: - controller (main thread only)

final class TalkbackController: NSObject, NSWindowDelegate {
    let model = TalkbackModel()
    var onSend: ((String) -> Void)?
    var onDismiss: (() -> Void)?

    private var panel: KeyablePanel?
    private var hosting: NSHostingController<TalkbackRoot>?
    private var dismissing = false
    /// Check-ins are free: with an empty field, the panel lets itself go this long
    /// after the eyes open. Any text in the field (typed or dictated) holds it.
    private let graceSecs = 4.0
    private var graceTimer: DispatchWorkItem?
    private var draftSub: AnyCancellable?

    func present(info: TalkbackAgentInfo, eyesClosed: Bool) {
        model.info = info
        model.eyesClosed = eyesClosed
        if panel == nil { buildPanel() }
        layout()
        panel?.makeKeyAndOrderFront(nil)
        updateGrace()
        if let p = panel {
            NSLog("[talkback] present frame=%@ visible=%d key=%d screen=%@ info=%@",
                  NSStringFromRect(p.frame), p.isVisible ? 1 : 0, p.isKeyWindow ? 1 : 0,
                  p.screen?.localizedName ?? "none", model.info == nil ? "nil" : "set")
        }
        // dev: dump what the panel actually renders (screenshots need permissions; this doesn't)
        if ProcessInfo.processInfo.environment["ANTIPHON_DEV"]?.hasPrefix("talkback") == true {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let hv = self?.hosting?.view,
                      let rep = hv.bitmapImageRepForCachingDisplay(in: hv.bounds) else { return }
                hv.cacheDisplay(in: hv.bounds, to: rep)
                if let data = rep.representation(using: .png, properties: [:]) {
                    let url = URL(fileURLWithPath: NSTemporaryDirectory())
                        .appendingPathComponent("talkback-dump.png")
                    try? data.write(to: url)
                    NSLog("[talkback] dump: %@ bounds=%@", url.path, NSStringFromRect(hv.bounds))
                }
            }
        }
    }

    /// Refresh content (a new narration line, a rebind) without re-summoning.
    func update(info: TalkbackAgentInfo) {
        guard panel?.isVisible == true else { return }
        model.info = info
        layout()
    }

    /// Eye state only gates the grace countdown now — the view is the letter either way.
    func setEyesClosed(_ closed: Bool) {
        guard panel?.isVisible == true, model.eyesClosed != closed else { return }
        model.eyesClosed = closed
        updateGrace()
    }

    /// (Re)arm or cancel the auto-dismiss: runs only while the panel is up, the eyes
    /// are open, and the field is empty. `draft` carries the in-flight value from the
    /// Combine willSet hook (model.draft still holds the previous keystroke there).
    private func updateGrace(draft: String? = nil) {
        graceTimer?.cancel()
        graceTimer = nil
        guard panel?.isVisible == true, !model.eyesClosed,
              (draft ?? model.draft).isEmpty else { return }
        let w = DispatchWorkItem { [weak self] in
            NSLog("[talkback] grace expired — letting go")
            self?.dismiss(notify: true)
        }
        graceTimer = w
        DispatchQueue.main.asyncAfter(deadline: .now() + graceSecs, execute: w)
    }

    func submit() {
        guard let info = model.info, info.reachable else { return }
        let text = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        onSend?(text)
        dismiss(notify: true)
    }

    func cancel() { dismiss(notify: true) }

    /// notify=false for engine-initiated teardown (agent freed) — no unlock echo.
    func dismiss(notify: Bool) {
        guard !dismissing, let p = panel, p.isVisible else { return }
        dismissing = true
        NSLog("[talkback] dismiss notify=%d", notify ? 1 : 0)
        graceTimer?.cancel()
        graceTimer = nil
        model.draft = ""
        p.orderOut(nil)
        dismissing = false
        if notify { onDismiss?() }
    }

    /// Click-away = the keyboard moved on = let go.
    func windowDidResignKey(_ notification: Notification) {
        NSLog("[talkback] resigned key → dismiss")
        dismiss(notify: true)
    }

    private func buildPanel() {
        let hc = NSHostingController(rootView: TalkbackRoot(model: model, controller: self))
        let p = KeyablePanel(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 220),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = false
        p.isReleasedWhenClosed = false
        p.animationBehavior = .utilityWindow
        p.isMovableByWindowBackground = true
        p.delegate = self
        p.contentView = hc.view
        p.onCancel = { [weak self] in self?.cancel() }
        panel = p
        hosting = hc
        // typing (or clearing) the field re-evaluates the grace countdown per keystroke
        draftSub = model.$draft.sink { [weak self] text in self?.updateGrace(draft: text) }
    }

    /// Spotlight placement: centered on the screen with the mouse, upper third.
    /// NSHostingController.sizeThatFits is the one sizing API that reliably measures
    /// an off-window SwiftUI tree (fittingSize / intrinsicContentSize report 0 / -1).
    private func layout() {
        guard let p = panel, let hc = hosting else { return }
        var size = hc.sizeThatFits(in: NSSize(width: 2000, height: 2000))
        if size.width < 200 || size.height < 80 {
            NSLog("[talkback] layout: degenerate size %@", NSStringFromSize(size))
            size = NSSize(width: 640, height: 240)
        }
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main
        guard let sf = screen?.visibleFrame else { return }
        let origin = NSPoint(x: sf.midX - size.width / 2,
                             y: sf.minY + sf.height * 0.72 - size.height)
        p.setFrame(NSRect(origin: origin, size: size), display: true)
    }
}

// MARK: - the input field

/// NSTextField wrapper: claims first responder the moment it lands in the panel (so
/// dictation works eyes-closed), Enter submits, Escape lets go. SwiftUI's FocusState
/// is unreliable inside non-activating panels; AppKit is not.
private struct PanelField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let enabled: Bool
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> FocusField {
        let f = FocusField()
        f.isBordered = false
        f.drawsBackground = false
        f.focusRingType = .none
        f.font = roundedFont(15, .regular)
        f.textColor = NSColor(TB.ink)
        f.delegate = context.coordinator
        f.lineBreakMode = .byTruncatingHead
        f.cell?.sendsActionOnEndEditing = false
        return f
    }

    func updateNSView(_ f: FocusField, context: Context) {
        context.coordinator.parent = self
        if f.stringValue != text {
            f.stringValue = text
            if let ed = f.currentEditor() {
                ed.selectedRange = NSRange(location: text.count, length: 0)
            }
        }
        f.isEditable = enabled
        f.isSelectable = enabled
        f.placeholderAttributedString = NSAttributedString(
            string: placeholder,
            attributes: [.foregroundColor: NSColor(TB.faint), .font: roundedFont(15, .regular)])
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PanelField
        init(_ parent: PanelField) { self.parent = parent }

        func controlTextDidChange(_ n: Notification) {
            guard let f = n.object as? NSTextField else { return }
            parent.text = f.stringValue
        }

        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)): parent.onSubmit(); return true
            case #selector(NSResponder.cancelOperation(_:)): parent.onCancel(); return true
            default: return false
            }
        }
    }
}

final class FocusField: NSTextField {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self, let w = self.window, self.isEditable else { return }
            w.makeFirstResponder(self)
        }
    }
}

private func roundedFont(_ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
    let f = NSFont.systemFont(ofSize: size, weight: weight)
    guard let d = f.fontDescriptor.withDesign(.rounded) else { return f }
    return NSFont(descriptor: d, size: size) ?? f
}

// MARK: - palette (the Her direction: warm paper, coral accent)

enum TB {
    static let paper = Color(red: 0.988, green: 0.965, blue: 0.937)   // #FCF6EF
    static let field = Color(red: 1.000, green: 0.992, blue: 0.976)   // #FFFDF9
    static let ink = Color(red: 0.271, green: 0.227, blue: 0.204)     // #453A34
    static let sub = Color(red: 0.592, green: 0.522, blue: 0.482)     // #97857B
    static let faint = Color(red: 0.710, green: 0.639, blue: 0.592)   // #B5A397
    static let coral = Color(red: 0.851, green: 0.396, blue: 0.314)   // #D96550
    static let sage = Color(red: 0.490, green: 0.624, blue: 0.467)    // #7D9F77
    static let amber = Color(red: 0.788, green: 0.592, blue: 0.247)   // #C9973F
    static let clay = Color(red: 0.741, green: 0.455, blue: 0.376)    // #BD7460
    static let hairline = Color(red: 0.365, green: 0.251, blue: 0.188).opacity(0.14)
}

extension Color {
    init(hexString: String) {
        var s = hexString
        if s.hasPrefix("#") { s.removeFirst() }
        let v = UInt64(s, radix: 16) ?? 0x888888
        self.init(red: Double((v >> 16) & 0xFF) / 255,
                  green: Double((v >> 8) & 0xFF) / 255,
                  blue: Double(v & 0xFF) / 255)
    }
}

/// "claude-code" → "Claude Code"
private func prettyKind(_ kind: String) -> String {
    kind.split(separator: "-").map { $0.prefix(1).uppercased() + $0.dropFirst() }
        .joined(separator: " ")
}

// (age labels + transcript tags localize via LAge/LTag in L10n.swift)

// MARK: - views

struct TalkbackRoot: View {
    @ObservedObject var model: TalkbackModel
    let controller: TalkbackController

    var body: some View {
        Group {
            if let info = model.info {
                LetterView(info: info, model: model, controller: controller)
            }
        }
        .preferredColorScheme(.light) // warm paper, whatever the system theme
    }
}

/// The paper the panel is printed on.
private struct Paper: ViewModifier {
    var radius: CGFloat
    func body(content: Content) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(TB.paper.opacity(0.97)))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .stroke(Color.white.opacity(0.75), lineWidth: 1))
    }
}

private struct KeyCap: View {
    let label: String
    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundColor(TB.sub)
            .padding(.horizontal, 7).padding(.vertical, 1.5)
            .frame(minWidth: 22)
            .background(RoundedRectangle(cornerRadius: 6).fill(TB.field))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(TB.hairline, lineWidth: 1))
    }
}

private struct InputRow: View {
    let info: TalkbackAgentInfo
    @ObservedObject var model: TalkbackModel
    let controller: TalkbackController

    var body: some View {
        let live = info.reachable
        HStack(spacing: 10) {
            PanelField(
                text: $model.draft,
                placeholder: info.reachable
                    ? Lf("tell %@…", info.name)
                    : Lf("%@ has no input path — it isn’t in a pane Antiphon can type into", info.name),
                enabled: info.reachable,
                onSubmit: { controller.submit() },
                onCancel: { controller.cancel() })
                .frame(height: 20)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .fill(live ? TB.field : TB.field.opacity(0.7)))
        .overlay(RoundedRectangle(cornerRadius: 13, style: .continuous)
            .stroke(live ? TB.coral.opacity(0.55) : TB.hairline, lineWidth: live ? 1.5 : 1))
        .shadow(color: live ? TB.coral.opacity(0.12) : .clear, radius: 4)
    }
}

/// Eyes open: header + mini-transcript + focused field + keycap footer.
private struct LetterView: View {
    let info: TalkbackAgentInfo
    @ObservedObject var model: TalkbackModel
    let controller: TalkbackController

    var body: some View {
        VStack(spacing: 0) {
            header
            if !info.lines.isEmpty { transcript }
            InputRow(info: info, model: model, controller: controller)
                .padding(.horizontal, 12).padding(.top, 4).padding(.bottom, 12)
            footer
        }
        .frame(width: 640)
        .modifier(Paper(radius: 20))
    }

    private var header: some View {
        HStack(spacing: 11) {
            Circle().fill(Color(hexString: info.colorHex))
                .frame(width: 13, height: 13)
                .shadow(color: Color(hexString: info.colorHex).opacity(0.7), radius: 5)
            Text(info.name)
                .font(.system(size: 16.5, weight: .bold, design: .rounded))
                .foregroundColor(TB.ink)
            if !info.kind.isEmpty {
                Text(prettyKind(info.kind))
                    .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                    .foregroundColor(TB.sub)
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .background(Capsule().fill(TB.ink.opacity(0.07)))
            }
            Spacer(minLength: 8)
            if !info.title.isEmpty {
                Text(info.title)
                    .font(.system(size: 12.5, design: .rounded))
                    .foregroundColor(TB.sub)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: 240, alignment: .trailing)
            }
            reachBadge
        }
        .padding(.horizontal, 18).padding(.top, 15).padding(.bottom, 13)
    }

    private var reachBadge: some View {
        HStack(spacing: 5) {
            Circle().fill(info.reachable ? TB.sage : TB.clay).frame(width: 7, height: 7)
            Text(info.reachable ? info.input : L("can’t hear you"))
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
                .foregroundColor(info.reachable ? TB.sage : TB.clay)
        }
    }

    private var transcript: some View {
        VStack(spacing: 9) {
            ForEach(Array(info.lines.enumerated()), id: \.offset) { i, line in
                let latest = i == info.lines.count - 1
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(LTag(line.kind))
                        .font(.system(size: 10.5, weight: .heavy, design: .rounded))
                        .kerning(1.0)
                        .foregroundColor(tagColor(line.kind))
                        .frame(width: 66, alignment: .trailing)
                    Text(line.text)
                        .font(.system(size: 14, design: .rounded))
                        .foregroundColor(latest ? TB.ink : TB.sub)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    Text(LAge(line.at))
                        .font(.system(size: 11, design: .rounded))
                        .foregroundColor(TB.faint)
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 2).padding(.bottom, 12)
    }

    private func tagColor(_ kind: String) -> Color {
        switch kind {
        case "done": return TB.sage
        case "blocked": return TB.amber
        default: return TB.faint
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            if info.reachable {
                HStack(spacing: 6) { KeyCap(label: "↩"); Text(Lf("send to %@", info.name)) }
            } else {
                Text(L("listening only")).foregroundColor(TB.clay)
            }
            Spacer()
            HStack(spacing: 6) { KeyCap(label: "esc"); Text(L("let go")) }
        }
        .font(.system(size: 12, design: .rounded))
        .foregroundColor(TB.sub)
        .padding(.horizontal, 16).padding(.vertical, 9)
        .background(TB.ink.opacity(0.035))
        .overlay(Rectangle().fill(TB.hairline).frame(height: 1), alignment: .top)
    }
}

