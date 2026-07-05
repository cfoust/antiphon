import AppKit
import Combine

/// The menu-bar eye. Open: the app is watching — camera on, eyes-closed
/// detection driving the antiphon. Click to close it: the camera stops (the
/// indicator light goes dark), the app goes silent and ignores your eyes
/// entirely. Click again to wake it.
///
/// NOTE: on notched MacBooks a crowded menu bar makes macOS silently hide
/// overflowing status items (the item exists but is never drawn) — so this
/// is a mirror, not the sole control: the main window has the same eye
/// button next to the gear. State lives in AntiphonEngine.watching; this
/// controller just displays it and reports clicks.
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private var watching = true
    private var sysLive = false
    private var sysMode = "off"
    var onToggle: (() -> Void)?
    var onCheckUpdates: (() -> Void)?
    var onSysMode: ((String) -> Void)?
    private var langSub: AnyCancellable?

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.button?.target = self
        it.button?.action = #selector(clicked)
        // left click toggles the eye; right click gets the standard app menu
        it.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        item = it
        refresh()
        langSub = I18n.shared.$lang.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    /// Reflect the app's watching state (called for clicks from EITHER control).
    func sync(_ on: Bool) {
        guard watching != on else { return }
        watching = on
        refresh()
    }

    /// Reflect the system-audio tap: wave arcs appear beside the eye while we
    /// are muting + re-emitting the Mac (that state must be visible somewhere).
    func syncSysAudio(live: Bool, mode: String) {
        guard sysLive != live || sysMode != mode else { return }
        sysLive = live
        sysMode = mode
        refresh()
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            onToggle?()
        }
    }

    /// The right-click menu — what every menu-bar Mac app owes its user:
    /// about, updates, settings, the state toggle, help, quit.
    private func showMenu() {
        let menu = NSMenu()

        let about = NSMenuItem(title: L("About Antiphon"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let updates = NSMenuItem(title: L("Check for Updates…"), action: #selector(checkUpdates), keyEquivalent: "")
        updates.target = self
        menu.addItem(updates)
        menu.addItem(.separator())

        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        // the rest of the Mac: mode picker, mirrored from Settings
        if #available(macOS 14.4, *) {
            let head = NSMenuItem(title: L("System audio passthrough"), action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            for (tag, label) in [("off", L("Default")), ("deaden", L("Quiet")), ("spatial", L("In the room"))] {
                let mi = NSMenuItem(title: label, action: #selector(pickSysMode(_:)), keyEquivalent: "")
                mi.target = self
                mi.representedObject = tag
                mi.state = sysMode == tag ? .on : .off
                mi.indentationLevel = 1
                menu.addItem(mi)
            }
            menu.addItem(.separator())
        }

        let docs = NSMenuItem(title: L("Antiphon Documentation"), action: #selector(openDocs), keyEquivalent: "")
        docs.target = self
        menu.addItem(docs)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: L("Quit Antiphon"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // transient assignment: a permanent .menu would eat left clicks too
        item?.menu = menu
        item?.button?.performClick(nil)
        item?.menu = nil
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func checkUpdates() { onCheckUpdates?() }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .init("antiphon.showSettings"), object: nil)
    }

    @objc private func openDocs() {
        if let u = URL(string: "https://antiphon.dev/docs/") { NSWorkspace.shared.open(u) }
    }

    @objc private func pickSysMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? String { onSysMode?(mode) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh() {
        guard let button = item?.button else { return }
        let name = watching ? "eye" : "eye.slash"
        let desc = watching ? L("Antiphon is watching") : L("Antiphon is asleep")
        button.image = statusImage(symbol: name, description: desc)
        var tip = watching
            ? L("Antiphon is watching — click to close its eyes (camera off, silent)")
            : L("Antiphon is asleep — click to wake it")
        if sysLive {
            tip += "\n" + (sysMode == "spatial"
                ? L("System audio is in the room")
                : L("System audio is quiet in the scene"))
        }
        button.toolTip = tip
    }

    /// The eye — with sound-wave arcs at its side while the system tap is
    /// live. Template image, so it follows the menu-bar appearance.
    private func statusImage(symbol: String, description: String) -> NSImage {
        let base = NSImage(systemSymbolName: symbol, accessibilityDescription: description)!
        guard sysLive else { return base }
        let size = NSSize(width: 26, height: 18)
        let img = NSImage(size: size)
        img.lockFocus()
        let b = base.size
        // eye nudged left so the waves get their own air
        base.draw(at: NSPoint(x: (size.width - b.width) / 2 - 2, y: (size.height - b.height) / 2),
                  from: .zero, operation: .sourceOver, fraction: 1)
        let c = NSPoint(x: size.width - 5.6, y: size.height / 2 + 0.5)
        for (r, alpha) in [(CGFloat(2.6), CGFloat(0.95)), (CGFloat(4.6), CGFloat(0.55))] {
            let arc = NSBezierPath()
            arc.appendArc(withCenter: c, radius: r, startAngle: -42, endAngle: 42)
            arc.lineWidth = 1.3
            NSColor.black.withAlphaComponent(alpha).set()
            arc.stroke()
        }
        img.unlockFocus()
        img.isTemplate = true
        img.accessibilityDescription = description
        return img
    }
}
