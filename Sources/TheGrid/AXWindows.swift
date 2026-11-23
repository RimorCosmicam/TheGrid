import AppKit
import ApplicationServices
import CoreGraphics

/// CoreGraphics' window number for an Accessibility window. Private, and the only way to tell
/// the two halves of the system that they are talking about the same window: the window list
/// knows where a window is and who owns it, Accessibility is what can move it. Every window
/// manager on the Mac uses this call.
@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement,
                                   _ identifier: UnsafeMutablePointer<CGWindowID>) -> AXError

/// One of the Mac's real windows, as the grid sees it.
struct DeskWindow {
    var id: CGWindowID
    var pid: pid_t
    var app: String
    var title: String
    /// Global screen coordinates, origin top left, the same ones Accessibility uses.
    var frame: CGRect
}

/// The Mac's windows: finding them, and moving them.
///
/// Nothing here draws anything. The grid is an arrangement of other apps' own windows, so that
/// what you see on the glasses is the real Safari, the real terminal, live and clickable, not a
/// picture of one.
final class AXWindows {
    /// Accessibility elements are expensive to look up and stay valid while the window lives.
    private var elements: [CGWindowID: AXUIElement] = [:]
    private var apps: [pid_t: AXUIElement] = [:]
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    /// macOS will not let a window be moved entirely out of sight: ask for a position further
    /// off than this and it keeps forty points of the window on the nearest screen. Measured, not
    /// documented. The grid leaves a margin this wide down each side of the glasses and covers it,
    /// so a window parked on the far side of the ring hides under it instead of leaving a stripe
    /// of itself along the edge.
    static let minimumVisible: CGFloat = 40

    /// Has the user ticked TheGrid in Privacy & Security > Accessibility? Without it the app can
    /// see windows but not touch them, so there is nothing to do but ask.
    static var isTrusted: Bool { AXIsProcessTrusted() }

    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// Every ordinary window on screen, front to back. Sheets, menus, the Dock and our own
    /// overlay are left out: only things a person would call a window.
    func onScreen() -> [DeskWindow] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { info -> DeskWindow? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != ownPID,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let frame = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            // Panels, HUDs and the odd invisible helper window: too small or too faint to be a
            // window someone wants on the ring.
            guard alpha > 0.05, frame.width > 120, frame.height > 80 else { return nil }
            let app = info[kCGWindowOwnerName as String] as? String ?? ""
            let title = info[kCGWindowName as String] as? String ?? ""
            return DeskWindow(id: id, pid: pid, app: app, title: title, frame: frame)
        }
    }

    /// The window under a point, the front one if several overlap. The window list is already in
    /// front-to-back order, so the first hit is the one the user was dragging.
    func window(at point: CGPoint, in windows: [DeskWindow]? = nil) -> DeskWindow? {
        (windows ?? onScreen()).first { $0.frame.contains(point) }
    }

    /// The Accessibility handle for a window, looked up through its owning app and kept.
    func element(for window: DeskWindow) -> AXUIElement? {
        if let cached = elements[window.id], isAlive(cached) { return cached }
        let app = apps[window.pid] ?? {
            let element = AXUIElementCreateApplication(window.pid)
            // An app that has stopped answering must not take the ring down with it. Long enough
            // that a heavy window laying itself out again still gets its next instruction -
            // Safari takes well over a tenth of a second to resize - and short enough that an app
            // which has genuinely hung costs one frame of one window.
            AXUIElementSetMessagingTimeout(element, 0.35)
            apps[window.pid] = element
            return element
        }()
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
              let list = value as? [AXUIElement] else { return nil }
        for candidate in list {
            var id: CGWindowID = 0
            if _AXUIElementGetWindow(candidate, &id) == .success {
                elements[id] = candidate
                if id == window.id { return candidate }
            }
        }
        return nil
    }

    func forget(_ id: CGWindowID) { elements[id] = nil }

    private func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &value) == .success
    }

    // MARK: - Moving

    func position(of element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &value) == .success,
              let axValue = value as! AXValue? else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    func size(of element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &value) == .success,
              let axValue = value as! AXValue? else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    func frame(of element: AXUIElement) -> CGRect? {
        guard let p = position(of: element), let s = size(of: element) else { return nil }
        return CGRect(origin: p, size: s)
    }

    func setPosition(_ point: CGPoint, of element: AXUIElement) {
        var p = point
        guard let value = AXValueCreate(.cgPoint, &p) else { return }
        AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value)
    }

    func setSize(_ size: CGSize, of element: AXUIElement) {
        var s = size
        guard let value = AXValueCreate(.cgSize, &s) else { return }
        AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value)
    }

    /// Position, then size, then position again.
    ///
    /// The order matters and it took the glasses to show it. An app clamps a window to the screen
    /// it is on at that moment, so sizing first asks for a window taller than the Mac's own
    /// screen and gets the Mac's screen height back. Moving it onto the glasses first means the
    /// size is measured against the glasses instead. The second move is because resizing from a
    /// corner the app chooses can shift the window, and one of the two positions is the one the
    /// grid asked for.
    func setFrame(_ frame: CGRect, of element: AXUIElement) {
        setPosition(frame.origin, of: element)
        setSize(frame.size, of: element)
        setPosition(frame.origin, of: element)
    }

    func raise(_ element: AXUIElement) {
        AXUIElementPerformAction(element, kAXRaiseAction as CFString)
    }

    func isMinimised(_ element: AXUIElement) -> Bool { flag(kAXMinimizedAttribute, of: element) }

    func isFullScreen(_ element: AXUIElement) -> Bool {
        flag("AXFullScreen", of: element)
    }

    private func flag(_ name: String, of element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return false
        }
        return (value as? Bool) ?? false
    }
}
