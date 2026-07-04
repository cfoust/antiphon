import AppKit
import Combine

/// The menu-bar eye. Open: the app is watching — camera on, eyes-closed
/// detection driving the chamber. Click to close it: the camera stops (the
/// indicator light goes dark), the app goes silent and ignores your eyes
/// entirely. Click again to wake it.
///
/// NOTE: on notched MacBooks a crowded menu bar makes macOS silently hide
/// overflowing status items (the item exists but is never drawn) — so this
/// is a mirror, not the sole control: the main window has the same eye
/// button next to the gear. State lives in ChamberEngine.watching; this
/// controller just displays it and reports clicks.
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private var watching = true
    var onToggle: (() -> Void)?
    private var langSub: AnyCancellable?

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.button?.target = self
        it.button?.action = #selector(clicked)
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

    @objc private func clicked() { onToggle?() }

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
