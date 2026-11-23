import AppKit
import GridCore

/// The menu bar item, and the wiring between the trackpad, the ring and the screens.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var settings = Settings.load()
    private let displays = DisplayWatcher()
    private var controller: RingController!
    private var gestures: GestureReader!
    private var status: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        controller = RingController(settings: settings)
        gestures = GestureReader(settings: settings)

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "square.grid.3x2",
                                       accessibilityDescription: "TheGrid")
        status.button?.image?.isTemplate = true
        rebuildMenu()

        controller.onStateChange = { [weak self] in self?.rebuildMenu() }

        displays.onChange = { [weak self] screen in
            self?.controller.use(screen: screen)
            self?.rebuildMenu()
        }

        gestures.onPan = { [weak self] columns in self?.controller.pan(columns: columns) }
        gestures.onPanEnd = { [weak self] in self?.controller.endPan() }
        gestures.onStep = { [weak self] columns in self?.controller.step(columns) }
        gestures.onDrop = { [weak self] point in self?.controller.drop(at: point) }
        gestures.onDrag = { [weak self] point in self?.controller.dragging(at: point) }
        gestures.onPress = { [weak self] point in self?.controller.press(at: point) }

        listenForCommands()
        displays.start()
        if AXWindows.isTrusted {
            gestures.start()
        } else if ProcessInfo.processInfo.environment["THEGRID_NO_PROMPT"] == nil {
            askForTrust()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Nobody wants to find their windows parked off the side of a screen that has gone.
        controller.releaseAll()
        gestures.stop()
    }

    // MARK: - Commands from outside

    private func listenForCommands() {
        let centre = DistributedNotificationCenter.default()
        centre.addObserver(forName: .init(Remote.pull), object: nil, queue: .main) { [weak self] note in
            let app = note.object as? String
            MainActor.assumeIsolated { self?.controller.pullInFrontWindow(matching: app) }
        }
        centre.addObserver(forName: .init(Remote.turn), object: nil, queue: .main) { [weak self] note in
            let columns = Int(note.object as? String ?? "1") ?? 1
            MainActor.assumeIsolated { self?.controller.step(columns) }
        }
        centre.addObserver(forName: .init(Remote.release), object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.controller.releaseAll() }
        }
    }

    // MARK: - Permission

    /// Without Accessibility the grid can see windows but not move them, which is the whole job.
    private func askForTrust() {
        AXWindows.requestTrust()
        let alert = NSAlert()
        alert.messageText = "TheGrid needs Accessibility"
        alert.informativeText = """
        The grid moves other apps' windows, and macOS only allows that with permission.

        Open System Settings > Privacy & Security > Accessibility and switch TheGrid on, then \
        choose Start from the menu bar.
        """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            NSWorkspace.shared.open(url)
        }
        // The switch takes effect without a restart, so keep an eye out for it.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] timer in
            guard AXWindows.isTrusted else { return }
            timer.invalidate()
            Task { @MainActor in
                self?.gestures.start()
                self?.rebuildMenu()
            }
        }
    }

    // MARK: - Menu

    private func rebuildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false

        let state: String
        if !AXWindows.isTrusted {
            state = "Waiting for Accessibility permission"
        } else if let screen = displays.current {
            state = "On \(screen.name) - \(Int(screen.bounds.width))x\(Int(screen.bounds.height))"
        } else {
            state = "Glasses not connected"
        }
        add(menu, state, enabled: false)
        if controller.isActive {
            add(menu, "\(controller.windowCount) window\(controller.windowCount == 1 ? "" : "s") on the ring, at slot \(controller.column + 1) of \(settings.ringColumns)",
                enabled: false)
        }
        menu.addItem(.separator())

        add(menu, "Pull in the front window", action: #selector(pullIn), enabled: controller.isActive)
        add(menu, "Hand every window back", action: #selector(releaseAll),
            enabled: controller.isActive && controller.windowCount > 0)
        menu.addItem(.separator())
        add(menu, "Turn left", action: #selector(turnLeft), enabled: controller.isActive)
        add(menu, "Turn right", action: #selector(turnRight), enabled: controller.isActive)
        menu.addItem(.separator())

        let gesture = NSMenu()
        for option in Settings.Gesture.allCases {
            let item = add(gesture, option.title, action: #selector(setGesture(_:)))
            item.representedObject = option.rawValue
            item.state = settings.gesture == option ? .on : .off
        }
        addSubmenu(menu, "Turn the ring with", gesture)

        let shape = NSMenu()
        for columns in [2, 3, 4] {
            let item = add(shape, "\(columns) across", action: #selector(setVisibleColumns(_:)))
            item.tag = columns
            item.state = settings.visibleColumns == columns ? .on : .off
        }
        shape.addItem(.separator())
        for rows in [1, 2, 3] {
            let item = add(shape, "\(rows) down", action: #selector(setRows(_:)))
            item.tag = rows
            item.state = settings.rows == rows ? .on : .off
        }
        shape.addItem(.separator())
        for ring in [6, 8, 12, 16, 24] {
            let item = add(shape, "\(ring) slots round", action: #selector(setRingColumns(_:)))
            item.tag = ring
            item.state = settings.ringColumns == ring ? .on : .off
        }
        addSubmenu(menu, "Grid", shape)

        let feel = NSMenu()
        for columns in [2, 3, 4, 6] {
            let item = add(feel, "A swipe turns \(columns) slots", action: #selector(setSwipe(_:)))
            item.tag = columns
            item.state = Int(settings.columnsPerSwipe) == columns ? .on : .off
        }
        feel.addItem(.separator())
        for pixels in [280, 420, 600] {
            let item = add(feel, "\(pixels) points of scroll a slot",
                           action: #selector(setScroll(_:)))
            item.tag = pixels
            item.state = Int(settings.pixelsPerColumn) == pixels ? .on : .off
        }
        addSubmenu(menu, "Sensitivity", feel)

        let backdrop = NSMenu()
        for (title, percent) in [("Solid", 100), ("Soft", 92), ("Softer", 80), ("Faint", 65)] {
            let item = add(backdrop, title, action: #selector(setBackdrop(_:)))
            item.tag = percent
            item.state = Int((settings.backdropOpacity * 100).rounded()) == percent ? .on : .off
        }
        addSubmenu(menu, "Backdrop", backdrop)

        let screens = NSMenu()
        let auto = add(screens, "The glasses, when plugged in", action: #selector(setDisplay(_:)))
        auto.tag = 0
        auto.state = displays.chosen == nil ? .on : .off
        screens.addItem(.separator())
        for screen in displays.all() {
            let item = add(screens, "\(screen.name)\(screen.isGlasses ? " (glasses)" : "")",
                           action: #selector(setDisplay(_:)))
            item.tag = Int(screen.id)
            item.state = displays.chosen == screen.id ? .on : .off
        }
        addSubmenu(menu, "Show the ring on", screens)

        let natural = add(menu, "Fingers move the view", action: #selector(toggleNatural))
        natural.state = settings.naturalDirection ? .on : .off
        let logging = add(menu, "Log the trackpad to the console", action: #selector(toggleLogging))
        logging.state = settings.logsGestures ? .on : .off

        menu.addItem(.separator())
        add(menu, "Quit TheGrid", action: #selector(quit))
        status.menu = menu
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, action: Selector? = nil,
                     enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.isEnabled = enabled && action != nil
        menu.addItem(item)
        return item
    }

    private func addSubmenu(_ menu: NSMenu, _ title: String, _ submenu: NSMenu) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.submenu = submenu
        menu.addItem(item)
    }

    // MARK: - Menu actions

    @objc private func pullIn() { controller.pullInFrontWindow() }
    @objc private func releaseAll() { controller.releaseAll() }
    @objc private func turnLeft() { controller.step(-1) }
    @objc private func turnRight() { controller.step(1) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func setGesture(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String,
              let option = Settings.Gesture(rawValue: raw) else { return }
        settings.gesture = option
        changed(restartGestures: true)
    }

    @objc private func setVisibleColumns(_ item: NSMenuItem) {
        settings.visibleColumns = item.tag
        changed()
    }

    @objc private func setRows(_ item: NSMenuItem) {
        settings.rows = item.tag
        changed()
    }

    @objc private func setRingColumns(_ item: NSMenuItem) {
        settings.ringColumns = item.tag
        changed()
    }

    @objc private func setDisplay(_ item: NSMenuItem) {
        displays.chosen = item.tag == 0 ? nil : CGDirectDisplayID(item.tag)
        rebuildMenu()
    }

    @objc private func setSwipe(_ item: NSMenuItem) {
        settings.columnsPerSwipe = Double(item.tag)
        changed()
    }

    @objc private func setScroll(_ item: NSMenuItem) {
        settings.pixelsPerColumn = Double(item.tag)
        changed()
    }

    @objc private func setBackdrop(_ item: NSMenuItem) {
        settings.backdropOpacity = Double(item.tag) / 100
        changed()
    }

    @objc private func toggleNatural() {
        settings.naturalDirection.toggle()
        changed()
    }

    @objc private func toggleLogging() {
        settings.logsGestures.toggle()
        changed()
    }

    private func changed(restartGestures: Bool = false) {
        settings.save()
        gestures.settings = settings
        controller.apply(settings: settings)
        if restartGestures, AXWindows.isTrusted { gestures.start() }
        rebuildMenu()
    }
}
