import CoreGraphics

/// The shape of the ring: how much of it the glasses show at once, and how far it goes round.
///
/// Everything here is in the Mac's global screen coordinates, the ones Accessibility and
/// CoreGraphics use: the origin is the top left of the main display and y grows downwards.
/// AppKit's own coordinates are flipped, so the app converts at the edges and nowhere else.
public struct GridGeometry: Equatable, Sendable {
    /// The glasses' display, where the ring is drawn.
    public var viewport: CGRect
    /// Slots across the glasses at any moment.
    public var visibleColumns: Int
    /// Slots down. The ring turns sideways only, so rows do not wrap.
    public var rows: Int
    /// Slots all the way round. Scrolling past the last one arrives back at the first.
    public var ringColumns: Int
    /// The gap between a window and the edge of its slot.
    public var padding: CGFloat

    public init(viewport: CGRect,
                visibleColumns: Int = 3,
                rows: Int = 2,
                ringColumns: Int = 12,
                padding: CGFloat = 10) {
        self.viewport = viewport
        self.visibleColumns = max(1, visibleColumns)
        self.rows = max(1, rows)
        // A ring smaller than the glasses would show the same slot twice at once.
        self.ringColumns = max(self.visibleColumns, ringColumns)
        self.padding = padding
    }

    public var slotSize: CGSize {
        CGSize(width: viewport.width / CGFloat(visibleColumns),
               height: viewport.height / CGFloat(rows))
    }

    public var slotCount: Int { ringColumns * rows }

    /// Brings a column index back into the ring, so column 12 of 12 is column 0.
    public func wrap(column: Int) -> Int {
        let n = ringColumns
        let m = column % n
        return m < 0 ? m + n : m
    }

    /// How far a column sits from the left edge of the glasses, counted in columns, taking the
    /// short way round: the ring has no ends, so the column behind your left shoulder is one step
    /// away rather than eleven. Measured around the middle of the view, which is what the eye
    /// takes as "ahead".
    public func columnDelta(_ column: Int, offset: Double) -> Double {
        let n = Double(ringColumns)
        let centre = Double(visibleColumns) / 2
        let low = centre - n / 2
        var d = (Double(column) - offset - low).truncatingRemainder(dividingBy: n)
        if d < 0 { d += n }
        return d + low
    }

    /// Where a placement's window belongs on screen at this scroll position, padding included.
    /// Columns out of sight come back with frames beyond the glasses; `park` keeps those from
    /// wandering off into other displays.
    public func frame(for placement: Placement, offset: Double) -> CGRect {
        let slot = slotSize
        let d = columnDelta(placement.column, offset: offset)
        let x = viewport.minX + CGFloat(d) * slot.width
        let y = viewport.minY + CGFloat(placement.row) * slot.height
        let w = slot.width * CGFloat(placement.columnSpan)
        let h = slot.height * CGFloat(placement.rowSpan)
        return park(CGRect(x: x + padding, y: y + padding,
                           width: max(80, w - padding * 2),
                           height: max(60, h - padding * 2)))
    }

    /// macOS will hold a window anywhere, seen or not. A window on the far side of the ring is
    /// kept just off the edge of the glasses — out of sight, but close enough that it slides in
    /// rather than appearing — and never so far that it lands on the Mac's own screen.
    public func park(_ frame: CGRect) -> CGRect {
        let slack: CGFloat = 64
        let left = viewport.minX - frame.width - slack
        let right = viewport.maxX + slack
        var f = frame
        f.origin.x = min(max(f.origin.x, left), right)
        return f
    }

    /// Is any of this window on the glasses?
    public func isOnScreen(_ frame: CGRect) -> Bool { frame.intersects(viewport) }

    /// The slot under a point on screen, for a window dropped or clicked there. Points outside
    /// the glasses have no slot.
    public func slot(at point: CGPoint, offset: Double) -> (column: Int, row: Int)? {
        guard viewport.contains(point) else { return nil }
        let slot = slotSize
        let dx = Double((point.x - viewport.minX) / slot.width)
        let dy = Int((point.y - viewport.minY) / slot.height)
        let column = wrap(column: Int((offset + dx).rounded(.down)))
        return (column, min(max(dy, 0), rows - 1))
    }

    /// How many slots a window of this size wants to cover. A window the user has dragged wider
    /// takes the span it is closest to, never more than the glasses can show.
    public func span(for size: CGSize) -> (columns: Int, rows: Int) {
        let slot = slotSize
        let c = Int((Double(size.width + padding * 2) / Double(slot.width)).rounded())
        let r = Int((Double(size.height + padding * 2) / Double(slot.height)).rounded())
        return (min(max(c, 1), visibleColumns), min(max(r, 1), rows))
    }

    /// The columns with any part of them on the glasses, left to right, for drawing the grid and
    /// for looking for a free slot near where you are.
    public func visibleColumnIndices(offset: Double) -> [Int] {
        let first = Int(offset.rounded(.down)) - 1
        return (first...(first + visibleColumns + 1)).map { wrap(column: $0) }
    }
}
