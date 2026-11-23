import AppKit
import CoreGraphics

/// Which screen is the glasses.
///
/// The Xreal Air is a plain DisplayPort monitor as far as macOS is concerned: 1920x1080, not
/// built in. That is what the grid looks for, and it follows the cable: unplug the glasses and
/// the ring hands every window back to the Mac's own screen.
final class DisplayWatcher {
    struct Screen {
        var id: CGDirectDisplayID
        /// In points, which is what windows are positioned in.
        var bounds: CGRect
        /// In pixels, which is what the panel in the glasses actually has.
        var pixels: CGSize
        /// The part of it a window can actually occupy. With "Displays have separate Spaces" on,
        /// which is the default, every screen carries its own menu bar: ask for a window under it
        /// and macOS quietly puts the window 30 points lower, which would knock every slot in the
        /// top row out of line. The grid uses this instead.
        var usable: CGRect
        var name: String
        var isBuiltIn: Bool
        var isGlasses: Bool
    }

    /// Nil when the glasses are not plugged in.
    var onChange: (Screen?) -> Void = { _ in }
    /// Set from the menu to use a screen the grid would not have picked, or by THEGRID_DISPLAY=main
    /// to work on the subject without the hardware on your head.
    var chosen: CGDirectDisplayID? {
        didSet { if chosen != oldValue { report() } }
    }

    private var observer: NSObjectProtocol?
    private(set) var current: Screen?

    init() {
        if let name = ProcessInfo.processInfo.environment["THEGRID_DISPLAY"] {
            if name == "main" { chosen = CGMainDisplayID() }
            else if let id = UInt32(name) { chosen = id }
        }
    }

    func start() {
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main) { [weak self] _ in self?.report() }
        report()
    }

    /// Every screen attached, for the menu.
    func all() -> [Screen] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetActiveDisplayList(count, &ids, &count)
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            let builtIn = CGDisplayIsBuiltin(id) != 0
            var pixels = bounds.size
            if let mode = CGDisplayCopyDisplayMode(id) {
                pixels = CGSize(width: mode.pixelWidth, height: mode.pixelHeight)
            }
            // The Air is 1920x1080, but macOS may be driving it at a scaled resolution, where the
            // points no longer say 1920. The panel behind it still does.
            let full = (pixels.width == 1920 && pixels.height == 1080)
                || (bounds.width == 1920 && bounds.height == 1080)
            return Screen(id: id,
                          bounds: bounds,
                          pixels: pixels,
                          usable: usableArea(of: id) ?? bounds,
                          name: name(of: id),
                          isBuiltIn: builtIn,
                          isGlasses: !builtIn && full)
        }
    }

    private func report() {
        let screens = all()
        let picked: Screen?
        if let chosen, let match = screens.first(where: { $0.id == chosen }) {
            picked = match
        } else if let glasses = screens.first(where: \.isGlasses) {
            picked = glasses
        } else {
            // One screen that is not this Mac's own: whatever it is, it is the one the user is
            // wearing or has plugged in, and the only sensible place for the ring.
            let external = screens.filter { !$0.isBuiltIn }
            picked = external.count == 1 ? external[0] : nil
        }
        guard picked?.id != current?.id || picked?.bounds != current?.bounds else { return }
        current = picked
        onChange(picked)
    }

    /// AppKit knows what the menu bar and the Dock have taken; it says so upside down.
    private func usableArea(of id: CGDirectDisplayID) -> CGRect? {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == id { return Coordinates.display(rect: screen.visibleFrame) }
        }
        return nil
    }

    private func name(of id: CGDirectDisplayID) -> String {
        for screen in NSScreen.screens {
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
            if number?.uint32Value == id { return screen.localizedName }
        }
        return "Display \(id)"
    }
}
