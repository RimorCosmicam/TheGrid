import AppKit
import GridCore

/// `TheGrid --doctor`: what the grid can see from where it is standing.
///
/// Permission is the thing that goes wrong, and it is invisible: the app looks the same whether
/// or not it is allowed to move a window. This says so, along with the screens it found and the
/// windows it would be willing to put on the ring. It changes nothing.
@MainActor
enum Doctor {
    static func report() {
        let trusted = AXWindows.isTrusted
        print("TheGrid 0.1")
        print("Accessibility: \(trusted ? "granted" : "NOT granted - the grid cannot move windows")")

        let displays = DisplayWatcher()
        print("\nScreens:")
        for screen in displays.all() {
            let kind = screen.isBuiltIn ? "built in" : (screen.isGlasses ? "glasses" : "external")
            print(String(format: "  %@  %.0fx%.0f points, %.0fx%.0f pixels, at (%.0f, %.0f)  [%@]",
                         screen.name, screen.bounds.width, screen.bounds.height,
                         screen.pixels.width, screen.pixels.height,
                         screen.bounds.minX, screen.bounds.minY, kind))
        }
        if displays.all().contains(where: \.isGlasses) == false {
            print("  no 1920x1080 external screen: plug the glasses in, or pick a screen from the menu")
        }

        let ax = AXWindows()
        let windows = ax.onScreen()
        print("\nWindows the ring would take (\(windows.count)):")
        for window in windows.prefix(30) {
            let element = trusted ? ax.element(for: window) : nil
            let movable = trusted ? (element == nil ? "not reachable" : "movable") : "unknown"
            print(String(format: "  %-22@ %-30@ %.0fx%.0f  [%@]",
                         window.app as NSString,
                         String(window.title.prefix(30)) as NSString,
                         window.frame.width, window.frame.height, movable as NSString))
        }

        if let glasses = displays.all().first(where: \.isGlasses) ?? displays.all().first {
            let settings = Settings.load()
            let geometry = GridGeometry(viewport: glasses.bounds,
                                        visibleColumns: settings.visibleColumns,
                                        rows: settings.rows,
                                        ringColumns: settings.ringColumns,
                                        padding: settings.padding)
            print("\nRing on \(glasses.name): \(settings.visibleColumns)x\(settings.rows) in view, "
                  + "\(geometry.slotCount) slots round, each "
                  + String(format: "%.0fx%.0f", geometry.slotSize.width, geometry.slotSize.height))
            print("Gesture: \(settings.gesture.title)")
        }
    }
}
