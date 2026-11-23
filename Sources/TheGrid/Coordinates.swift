import AppKit
import CoreGraphics

/// The Mac has two ideas of where things are. Accessibility, the window list and the displays all
/// measure from the top left of the main screen with y going down; AppKit measures from the
/// bottom left with y going up. The grid thinks in the first kind, because that is what moves
/// windows, and converts only where it meets AppKit.
enum Coordinates {
    static var primaryHeight: CGFloat {
        if let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) {
            return primary.frame.height
        }
        return NSScreen.main?.frame.height ?? 0
    }

    /// A rectangle in display coordinates, as an AppKit screen rectangle.
    static func appKit(_ rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A point in AppKit screen coordinates, in display coordinates.
    static func display(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: primaryHeight - point.y)
    }

    /// An AppKit screen rectangle, in display coordinates. The same flip either way round.
    static func display(rect: CGRect) -> CGRect {
        CGRect(x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
}
