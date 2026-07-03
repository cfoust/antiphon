import AppKit
import Combine

/// The menu-bar eye. Open: the app is watching — camera on, eyes-closed
/// detection driving the chamber. Click to close it: the camera stops (the
/// indicator light goes dark), the app goes silent and ignores your eyes
/// entirely. Click again to wake it.
final class MenuBarController: NSObject {
    private var item: NSStatusItem?
    private(set) var watching = true
    var onToggle: ((Bool) -> Void)?
    private var langSub: AnyCancellable?

    func install() {
        guard item == nil else { return }
        let it = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        it.button?.target = self
        it.button?.action = #selector(toggle)
        item = it
        refresh()
        langSub = I18n.shared.$lang.sink { [weak self] _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    @objc private func toggle() {
        watching.toggle()
        refresh()
        onToggle?(watching)
    }

    private func refresh() {
        guard let button = item?.button else { return }
        let name = watching ? "eye" : "eye.slash"
        let desc = watching ? L("Chamber is watching") : L("Chamber is asleep")
        button.image = NSImage(systemSymbolName: name, accessibilityDescription: desc)
        button.toolTip = watching
            ? L("Chamber is watching — click to close its eyes (camera off, silent)")
            : L("Chamber is asleep — click to wake it")
    }
}
