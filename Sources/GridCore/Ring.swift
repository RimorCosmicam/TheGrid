import CoreGraphics

/// A window's identity, the number CoreGraphics gives it. Stable while the window lives.
public typealias WindowKey = UInt32

/// Where a window sits on the ring: its top left slot and how many slots it covers.
public struct Placement: Equatable, Hashable, Sendable {
    public var column: Int
    public var row: Int
    public var columnSpan: Int
    public var rowSpan: Int

    public init(column: Int, row: Int, columnSpan: Int = 1, rowSpan: Int = 1) {
        self.column = column
        self.row = row
        self.columnSpan = max(1, columnSpan)
        self.rowSpan = max(1, rowSpan)
    }
}

/// Which windows are on the ring and which slots they fill.
///
/// The ring holds the arrangement; it does not touch windows. The app reads it to decide where
/// every window should be, and writes to it when one is dropped in, resized or let go.
public struct Ring: Equatable, Sendable {
    public var geometry: GridGeometry
    public private(set) var placements: [WindowKey: Placement] = [:]
    /// Front to back among windows sharing slots: the last one dropped or clicked wins.
    public private(set) var order: [WindowKey] = []

    public init(geometry: GridGeometry) { self.geometry = geometry }

    public var windows: [WindowKey] { order }

    public func placement(of key: WindowKey) -> Placement? { placements[key] }

    public mutating func put(_ key: WindowKey, at placement: Placement) {
        var p = placement
        p.column = geometry.wrap(column: p.column)
        p.row = min(max(p.row, 0), geometry.rows - p.rowSpan.clamped(to: 1...geometry.rows))
        p.columnSpan = min(p.columnSpan, geometry.visibleColumns)
        p.rowSpan = min(p.rowSpan, geometry.rows)
        placements[key] = p
        order.removeAll { $0 == key }
        order.append(key)
    }

    public mutating func remove(_ key: WindowKey) {
        placements[key] = nil
        order.removeAll { $0 == key }
    }

    public mutating func raise(_ key: WindowKey) {
        guard placements[key] != nil else { return }
        order.removeAll { $0 == key }
        order.append(key)
    }

    /// Every slot a placement covers, wrapped round the ring.
    public func cells(of placement: Placement) -> [(column: Int, row: Int)] {
        var out: [(Int, Int)] = []
        for c in 0..<placement.columnSpan {
            for r in 0..<placement.rowSpan {
                let row = placement.row + r
                guard row < geometry.rows else { continue }
                out.append((geometry.wrap(column: placement.column + c), row))
            }
        }
        return out
    }

    /// Nothing else there?
    public func isFree(_ placement: Placement, ignoring key: WindowKey? = nil) -> Bool {
        guard placement.row + placement.rowSpan <= geometry.rows else { return false }
        let wanted = Set(cells(of: placement).map { $0.column * 1000 + $0.row })
        for (other, p) in placements where other != key {
            let taken = Set(cells(of: p).map { $0.column * 1000 + $0.row })
            if !wanted.isDisjoint(with: taken) { return false }
        }
        return true
    }

    /// The free slot closest to where a window was dropped: the one under the pointer if it is
    /// empty, otherwise the nearest empty one, searched outwards along the ring so a drop lands
    /// in front of you rather than behind your back.
    public func nearestFree(to wanted: Placement, ignoring key: WindowKey? = nil) -> Placement? {
        if isFree(wanted, ignoring: key) { return wanted }
        let rowOrder = [wanted.row] + (0..<geometry.rows).filter { $0 != wanted.row }
        for step in 0...(geometry.ringColumns / 2 + 1) {
            for dc in (step == 0 ? [0] : [step, -step]) {
                for row in rowOrder {
                    var candidate = wanted
                    candidate.column = geometry.wrap(column: wanted.column + dc)
                    candidate.row = row
                    guard candidate.row + candidate.rowSpan <= geometry.rows else { continue }
                    if isFree(candidate, ignoring: key) { return candidate }
                }
            }
        }
        return nil
    }

    /// A free slot near what the glasses are showing, for pulling a window in without aiming.
    public func firstFree(near offset: Double, span: (columns: Int, rows: Int) = (1, 1)) -> Placement? {
        let start = Int(offset.rounded())
        for dc in 0..<geometry.ringColumns {
            for row in 0..<geometry.rows {
                let candidate = Placement(column: geometry.wrap(column: start + dc),
                                          row: row,
                                          columnSpan: span.columns,
                                          rowSpan: span.rows)
                if isFree(candidate) { return candidate }
            }
        }
        return nil
    }

    /// Where every window on the ring belongs right now, nearest the eye last so that windows
    /// sharing a slot stack the way the user expects.
    public func frames(offset: Double) -> [(key: WindowKey, frame: CGRect, onScreen: Bool)] {
        order.compactMap { key in
            guard let p = placements[key] else { return nil }
            let frame = geometry.frame(for: p, offset: offset)
            return (key, frame, geometry.isOnScreen(frame))
        }
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
