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
    var onSysMode: ((String) -> Void)?
    var onSysVolume: ((Double) -> Void)?
    var sysVolume: (() -> Double)?
    /// Whether system-audio recording permission is granted — the mode picker
    /// in the right-click menu must never be the thing that fires the TCC
    /// prompt (Settings owns the explicit ask).
    var sysPermitted: (() -> Bool)?
    private var langSub: AnyCancellable?

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.button?.target = self
        it.button?.action = #selector(clicked)
        // left click (up) toggles the eye; right click opens the menu on mouse
        // DOWN, like every menu bar item — .rightMouseUp alone has grown
        // unreliable for status items on recent macOS
        it.button?.sendAction(on: [.leftMouseUp, .rightMouseDown])
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
        let e = NSApp.currentEvent
        // right click OR control-click (the trackpad's right) opens the menu
        if e?.type == .rightMouseDown || e?.type == .rightMouseUp
            || e?.modifierFlags.contains(.control) == true {
            showMenu()
        } else {
            onToggle?()
        }
    }

    /// The right-click menu, kept SHORT — a long menu scrolls under the menu
    /// bar. About, settings, the system-audio picker, quit; docs and updates
    /// live in Settings.
    private func showMenu() {
        let menu = NSMenu()

        let about = NSMenuItem(title: L("About Antiphon"), action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let settings = NSMenuItem(title: L("Settings…"), action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(.separator())

        // the rest of the Mac: mode picker, mirrored from Settings — but only
        // once the recording permission has been granted there; before that,
        // one item that leads to the explicit ask instead
        if #available(macOS 14.4, *) {
            let head = NSMenuItem(title: L("System audio passthrough"), action: nil, keyEquivalent: "")
            head.isEnabled = false
            menu.addItem(head)
            if sysPermitted?() == true {
                for (tag, label) in [("off", L("Default")), ("deaden", L("Quiet")), ("spatial", L("In the room"))] {
                    let mi = NSMenuItem(title: label, action: #selector(pickSysMode(_:)), keyEquivalent: "")
                    mi.target = self
                    mi.representedObject = tag
                    mi.state = sysMode == tag ? .on : .off
                    mi.indentationLevel = 1
                    menu.addItem(mi)
                }
                if sysMode != "off" { menu.addItem(volumeItem()) }
            } else {
                let ask = NSMenuItem(title: L("Allow recording in Settings…"),
                                     action: #selector(openSettings), keyEquivalent: "")
                ask.target = self
                ask.indentationLevel = 1
                menu.addItem(ask)
            }
            menu.addItem(.separator())
        }

        let quit = NSMenuItem(title: L("Quit Antiphon"), action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        // popUp, not the transient item.menu + performClick(nil) dance: that
        // trick stopped opening the menu on recent macOS (the button is
        // already mid-click when the action runs), and a permanent .menu
        // would eat left clicks too
        guard let button = item?.button else { return }
        menu.popUp(positioning: nil,
                   at: NSPoint(x: 0, y: button.bounds.maxY + 5), in: button)
    }

    /// The system-audio level, inline under the mode rows (speaker glyphs at
    /// the ends, like the sound menu). Lives in an NSMenuItem view so it
    /// tracks live without closing the menu.
    private func volumeItem() -> NSMenuItem {
        let width = 210.0
        let container = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 26))
        let slider = NSSlider(value: sysVolume?() ?? 1.0, minValue: 0, maxValue: 1,
                              target: self, action: #selector(volumeChanged(_:)))
        slider.isContinuous = true
        slider.controlSize = .small
        let lo = NSImageView(image: NSImage(systemSymbolName: "speaker.fill",
                                            accessibilityDescription: nil)!)
        let hi = NSImageView(image: NSImage(systemSymbolName: "speaker.wave.3.fill",
                                            accessibilityDescription: nil)!)
        for v in [lo, hi] { v.contentTintColor = .tertiaryLabelColor }
        // indentationLevel doesn't apply to view items — pad to match the modes
        lo.frame = NSRect(x: 25, y: 7, width: 13, height: 12)
        slider.frame = NSRect(x: 42, y: 3, width: width - 42 - 32, height: 20)
        hi.frame = NSRect(x: width - 28, y: 7, width: 16, height: 12)
        container.addSubview(lo)
        container.addSubview(slider)
        container.addSubview(hi)
        let mi = NSMenuItem()
        mi.view = container
        return mi
    }

    @objc private func volumeChanged(_ sender: NSSlider) {
        onSysVolume?(sender.doubleValue)
    }

    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }

    @objc private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .init("antiphon.showSettings"), object: nil)
    }

    @objc private func pickSysMode(_ sender: NSMenuItem) {
        if let mode = sender.representedObject as? String { onSysMode?(mode) }
    }

    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh() {
        guard let button = item?.button else { return }
        // the sysLive composite is 26 pt wide — squareLength (~22 pt) would
        // clip the wave arcs right back off the image
        item?.length = sysLive ? 30 : NSStatusItem.squareLength
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
