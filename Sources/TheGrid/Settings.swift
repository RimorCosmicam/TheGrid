import Foundation

/// What the ring is shaped like and how it is turned. Kept in the usual place, so it survives a
/// restart and can be changed from the menu.
struct Settings {
    enum Gesture: String, CaseIterable {
        case threeFingers
        case optionScroll
        case both

        var allowsTouches: Bool { self != .optionScroll }
        var allowsOptionScroll: Bool { self != .threeFingers }

        var title: String {
            switch self {
            case .threeFingers: return "Three fingers"
            case .optionScroll: return "Option and scroll"
            case .both: return "Either"
            }
        }
    }

    var gesture: Gesture = .both
    var visibleColumns = 3
    var rows = 2
    var ringColumns = 12
    var padding = 10.0
    /// A swipe across the whole trackpad turns the ring this far.
    var columnsPerSwipe = 3.0
    /// Scrolled with the option key held, this much wheel moves the ring one slot.
    var pixelsPerColumn = 420.0
    /// Fingers left, ring turns right: the way the content follows the fingers, as on the phone.
    var naturalDirection = true
    var logsGestures = false
    /// How solid the dark panel behind the slots is. Not quite solid by default: a hint of the
    /// desktop through the tiles gives the grid something to sit on, rather than a void.
    var backdropOpacity = 0.92

    private static let key = "settings"

    static func load() -> Settings {
        var s = Settings()
        // THEGRID_LOG=1 turns the trackpad log on for one run, without going to the menu.
        if ProcessInfo.processInfo.environment["THEGRID_LOG"] != nil { s.logsGestures = true }
        let d = UserDefaults.standard
        guard let saved = d.dictionary(forKey: key) else { return s }
        if let v = saved["gesture"] as? String, let g = Gesture(rawValue: v) { s.gesture = g }
        if let v = saved["visibleColumns"] as? Int { s.visibleColumns = v }
        if let v = saved["rows"] as? Int { s.rows = v }
        if let v = saved["ringColumns"] as? Int { s.ringColumns = v }
        if let v = saved["padding"] as? Double { s.padding = v }
        if let v = saved["columnsPerSwipe"] as? Double { s.columnsPerSwipe = v }
        if let v = saved["pixelsPerColumn"] as? Double { s.pixelsPerColumn = v }
        if let v = saved["naturalDirection"] as? Bool { s.naturalDirection = v }
        if let v = saved["logsGestures"] as? Bool { s.logsGestures = s.logsGestures || v }
        if let v = saved["backdropOpacity"] as? Double { s.backdropOpacity = v }
        return s
    }

    func save() {
        UserDefaults.standard.set([
            "gesture": gesture.rawValue,
            "visibleColumns": visibleColumns,
            "rows": rows,
            "ringColumns": ringColumns,
            "padding": padding,
            "columnsPerSwipe": columnsPerSwipe,
            "pixelsPerColumn": pixelsPerColumn,
            "naturalDirection": naturalDirection,
            "logsGestures": logsGestures,
            "backdropOpacity": backdropOpacity,
        ], forKey: Settings.key)
    }
}
