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
    var onToggle: (() -> Void)?
    var onCheckUpdates: (() -> Void)?
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

    @objc private func quit() { NSApp.terminate(nil) }

    private func refresh() {
        guard let button = item?.button else { return }
        let name = watching ? "eye" : "eye.slash"
        let desc = watching ? L("Antiphon is watching") : L("Antiphon is asleep")
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: desc)
        button.toolTip = watching
            ? L("Antiphon is watching — click to close its eyes (camera off, silent)")
            : L("Antiphon is asleep — click to wake it")
    }
}
