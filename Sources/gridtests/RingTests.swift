import CoreGraphics
import Foundation
import GridCore

/// The glasses: 1920x1080 sitting above a Mac screen, so negative y, as macOS would have it.
let glasses = CGRect(x: 320, y: -1080, width: 1920, height: 1080)
let geo = GridGeometry(viewport: glasses, visibleColumns: 3, rows: 2, ringColumns: 12, padding: 10)

func geometryTests() {
    run("slots divide the glasses") {
        Check.close(Double(geo.slotSize.width), 640, "slot width")
        Check.close(Double(geo.slotSize.height), 540, "slot height")
        Check.equal(geo.slotCount, 24, "slots round the ring")
    }

    run("columns wrap round the ring") {
        Check.equal(geo.wrap(column: 12), 0, "past the end")
        Check.equal(geo.wrap(column: -1), 11, "before the start")
    }

    run("a column takes the short way round") {
        // Standing at column 0 with three columns in view, column 11 is one step behind, not
        // eleven ahead: it should sit just off the left edge, not three screens to the right.
        Check.close(geo.columnDelta(11, offset: 0), -1, "behind the left edge")
        Check.close(geo.columnDelta(1, offset: 0), 1, "the next one along")
        Check.close(geo.columnDelta(0, offset: 0.5), -0.5, "half a slot of scroll")
    }

    run("frames land on slot boundaries") {
        let f = geo.frame(for: Placement(column: 1, row: 1), offset: 0)
        Check.close(Double(f.minX), Double(glasses.minX) + 640 + 10, "second column")
        Check.close(Double(f.minY), Double(glasses.minY) + 540 + 10, "second row")
        Check.close(Double(f.width), 620, "padded width")
        Check.close(Double(f.height), 520, "padded height")
    }

    run("a window spanning two columns is twice as wide") {
        let f = geo.frame(for: Placement(column: 0, row: 0, columnSpan: 2, rowSpan: 2), offset: 0)
        Check.close(Double(f.width), 1280 - 20, "two columns")
        Check.close(Double(f.height), 1080 - 20, "two rows")
    }

    run("the far side of the ring is parked just out of sight") {
        let f = geo.frame(for: Placement(column: 6, row: 0), offset: 0)
        Check.that(!geo.isOnScreen(f), "not on the glasses")
        Check.that(f.maxX < glasses.minX || f.minX > glasses.maxX, "fully outside")
        Check.that(f.minX > glasses.minX - 3000, "not off in the far distance")
    }

    run("a slot is found under a point") {
        let p = geo.slot(at: CGPoint(x: glasses.minX + 700, y: glasses.minY + 600), offset: 0)
        Check.equal(p?.column, 1, "second column")
        Check.equal(p?.row, 1, "second row")
        Check.that(geo.slot(at: CGPoint(x: 400, y: 400), offset: 0) == nil, "nothing off the glasses")
        let scrolled = geo.slot(at: CGPoint(x: glasses.minX + 10, y: glasses.minY + 10), offset: 5)
        Check.equal(scrolled?.column, 5, "scrolled five along")
    }

    run("a window's size picks its span") {
        Check.equal(geo.span(for: CGSize(width: 620, height: 520)).columns, 1, "one slot")
        Check.equal(geo.span(for: CGSize(width: 1260, height: 520)).columns, 2, "two slots")
        Check.equal(geo.span(for: CGSize(width: 4000, height: 4000)).columns, 3, "no wider than the view")
        Check.equal(geo.span(for: CGSize(width: 100, height: 100)).rows, 1, "never nothing")
    }
}

func occupancyTests() {
    run("slots fill up and free again") {
        var ring = Ring(geometry: geo)
        ring.put(1, at: Placement(column: 0, row: 0))
        Check.that(!ring.isFree(Placement(column: 0, row: 0)), "taken")
        Check.that(ring.isFree(Placement(column: 0, row: 1)), "the row below is free")
        Check.that(ring.isFree(Placement(column: 0, row: 0), ignoring: 1), "free to itself")
        ring.remove(1)
        Check.that(ring.isFree(Placement(column: 0, row: 0)), "free again")
    }

    run("a wide window blocks both its slots") {
        var ring = Ring(geometry: geo)
        ring.put(1, at: Placement(column: 0, row: 0, columnSpan: 2))
        Check.that(!ring.isFree(Placement(column: 1, row: 0)), "second slot taken too")
        Check.that(ring.isFree(Placement(column: 2, row: 0)), "third still free")
    }

    run("a drop on a full slot moves along the ring") {
        var ring = Ring(geometry: geo)
        ring.put(1, at: Placement(column: 3, row: 0))
        ring.put(2, at: Placement(column: 3, row: 1))
        let found = ring.nearestFree(to: Placement(column: 3, row: 0))
        Check.that(found != nil, "somewhere free")
        Check.that(found?.column == 2 || found?.column == 4, "the next column either side")
    }

    run("the ring can fill right up") {
        var ring = Ring(geometry: geo)
        for i in 0..<24 {
            guard let slot = ring.firstFree(near: 0) else { break }
            ring.put(WindowKey(i + 1), at: slot)
        }
        Check.equal(ring.windows.count, 24, "every slot used")
        Check.that(ring.firstFree(near: 0) == nil, "and no room left")
    }

    run("the last window touched is the front one") {
        var ring = Ring(geometry: geo)
        ring.put(1, at: Placement(column: 0, row: 0))
        ring.put(2, at: Placement(column: 1, row: 0))
        ring.raise(1)
        Check.equal(ring.windows.last, 1, "raised to the front")
    }

    run("frames say which windows are in sight") {
        var ring = Ring(geometry: geo)
        ring.put(1, at: Placement(column: 0, row: 0))
        ring.put(2, at: Placement(column: 6, row: 0))
        let frames = ring.frames(offset: 0)
        Check.equal(frames.filter(\.onScreen).count, 1, "one of the two on the glasses")
        Check.equal(frames.first(where: \.onScreen)?.key, 1, "the near one")
    }
}

func scrollTests() {
    run("dragging follows the fingers") {
        var s = RingScroller(ringColumns: 12)
        s.drag(columns: 0.25, at: 0)
        s.drag(columns: 0.25, at: 1.0 / 60)
        Check.close(s.offset, 0.5, "half a slot")
    }

    run("a flick settles on a whole slot") {
        var s = RingScroller(ringColumns: 12)
        var t = 0.0
        for _ in 0..<10 { t += 1.0 / 60; s.drag(columns: 0.08, at: t) }
        s.release()
        var steps = 0
        while s.advance(by: 1.0 / 60), steps < 600 { steps += 1 }
        Check.close(s.offset, s.offset.rounded(), "resting on a slot")
        Check.that(s.offset >= 1, "the flick carried it on at least one slot")
        Check.that(steps < 180, "settled within three seconds")
        Check.that(!s.isMoving, "and stopped")
    }

    run("a hard flick is held to three slots") {
        var s = RingScroller(ringColumns: 12)
        var t = 0.0
        for _ in 0..<10 { t += 1.0 / 60; s.drag(columns: 1.5, at: t) }
        s.release()
        while s.advance(by: 1.0 / 60) {}
        Check.that(s.offset - 15 <= 3.001, "no more than three slots past the drag")
    }

    run("stepping moves one slot at a time") {
        var s = RingScroller(ringColumns: 12)
        s.step(columns: 1)
        while s.advance(by: 1.0 / 60) {}
        Check.close(s.offset, 1, "one along")
        s.step(columns: -1)
        while s.advance(by: 1.0 / 60) {}
        Check.close(s.offset, 0, "and back")
    }

    run("going right round comes back to the start") {
        var s = RingScroller(ringColumns: 12)
        s.offset = 11.5
        s.step(columns: 1)
        while s.advance(by: 1.0 / 60) {}
        Check.close(s.offset, 0, "wrapped to the beginning")
    }

    run("the settle never overshoots into a bounce") {
        var s = RingScroller(ringColumns: 12)
        s.offset = 0
        s.step(columns: 1)
        var maximum = 0.0
        while s.advance(by: 1.0 / 120) { maximum = max(maximum, s.offset) }
        Check.that(maximum <= 1.001, "no bounce past the slot")
    }
}
