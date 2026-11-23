import AppKit
import GridCore

/// What the grid itself looks like: the slots, which one you are looking at, and where a window
/// will land if you let go of it here.
///
/// Two windows, because the chrome belongs on both sides of the apps. The backdrop sits behind
/// every window, so the empty slots show as a grid the apps sit in rather than a frame drawn over
/// them. The marker sits above everything, for the moment a window is being dropped. Neither
/// takes a click: the windows on the ring are real windows and every click is theirs.
@MainActor
final class Overlay {
    private var backdrop: NSWindow?
    private var marker: NSWindow?
    private let backdropView = GridBackdropView()
    private let markerView = DropMarkerView()

    /// `bounds` is the whole screen, `usable` the part of it windows can reach. The margins down
    /// each side of the usable area are masked: that is where windows on the far side of the ring
    /// are parked, and macOS insists on leaving a little of them showing.
    func show(on bounds: CGRect, usable: CGRect) {
        markerView.margins = [
            CGRect(x: usable.minX, y: usable.minY,
                   width: AXWindows.minimumVisible, height: usable.height),
            CGRect(x: usable.maxX - AXWindows.minimumVisible, y: usable.minY,
                   width: AXWindows.minimumVisible, height: usable.height),
        ]
        let frame = Coordinates.appKit(bounds)
        backdrop = backdrop ?? make(level: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1,
                                    view: backdropView)
        marker = marker ?? make(level: Int(CGWindowLevelForKey(.screenSaverWindow)), view: markerView)
        for window in [backdrop, marker].compactMap({ $0 }) {
            window.setFrame(frame, display: false)
            window.orderFrontRegardless()
        }
    }

    func hide() {
        backdrop?.orderOut(nil)
        marker?.orderOut(nil)
        backdrop = nil
        marker = nil
    }

    /// The ring moved, or its contents changed.
    func update(ring: Ring, offset: Double) {
        backdropView.ring = ring
        backdropView.offset = offset
        backdropView.needsDisplay = true
    }

    func set(backdropOpacity: Double) {
        backdropView.opacity = backdropOpacity
        backdropView.needsDisplay = true
    }

    /// Where the window being dragged would land, or nothing once it has landed.
    func markDrop(_ frame: CGRect?) {
        markerView.target = frame.map { Coordinates.appKit($0) }
        markerView.needsDisplay = true
    }

    private func make(level: Int, view: NSView) -> NSWindow {
        let window = NSWindow(contentRect: .zero, styleMask: .borderless,
                              backing: .buffered, defer: false)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = NSWindow.Level(rawValue: level)
        window.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenNone]
        window.contentView = view
        return window
    }
}

/// The grid behind the apps.
final class GridBackdropView: NSView {
    var ring = Ring(geometry: GridGeometry(viewport: .zero))
    var offset: Double = 0
    var opacity: Double = 0.92

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let geometry = ring.geometry
        guard geometry.viewport.width > 0 else { return }
        let slot = geometry.slotSize

        // Not quite solid, by default. The panel in the glasses shows black by emitting nothing,
        // so a little of the desktop coming through is what gives the tiles something to sit on.
        // Turn it up to solid from the menu for a grid that floats in the dark instead.
        context.setFillColor(NSColor.black.withAlphaComponent(CGFloat(opacity)).cgColor)
        context.fill(bounds)

        // The window covers the whole screen; the ring lives in the part of it windows can
        // reach, which starts below that screen's menu bar.
        let area = region

        var occupied: Set<Int> = []
        for key in ring.windows {
            guard let placement = ring.placement(of: key) else { continue }
            for cell in ring.cells(of: placement) { occupied.insert(cell.column * 1000 + cell.row) }
        }

        for column in geometry.visibleColumnIndices(offset: offset) {
            let delta = geometry.columnDelta(column, offset: offset)
            let x = area.minX + CGFloat(delta) * slot.width
            for row in 0..<geometry.rows {
                // AppKit draws from the bottom up; the ring counts rows from the top down.
                let y = area.maxY - CGFloat(row + 1) * slot.height
                let cell = CGRect(x: x, y: y, width: slot.width, height: slot.height)
                    .insetBy(dx: CGFloat(geometry.padding), dy: CGFloat(geometry.padding))
                let taken = occupied.contains(geometry.wrap(column: column) * 1000 + row)
                let path = NSBezierPath(roundedRect: cell, xRadius: 14, yRadius: 14)
                path.lineWidth = 1
                if taken {
                    NSColor.white.withAlphaComponent(0.06).setStroke()
                } else {
                    NSColor.white.withAlphaComponent(0.14).setStroke()
                    NSColor.white.withAlphaComponent(0.02).setFill()
                    path.fill()
                }
                path.stroke()
                if !taken { drawPlus(in: cell, context: context) }
            }
        }

        drawRingIndicator(in: context)
    }

    /// An empty slot says only that it is empty: a cross, the size of a cursor, waiting for
    /// something to be dropped on it.
    private func drawPlus(in cell: CGRect, context: CGContext) {
        let arm: CGFloat = 15
        context.saveGState()
        context.setStrokeColor(NSColor.white.withAlphaComponent(0.22).cgColor)
        context.setLineWidth(2)
        context.setLineCap(.round)
        context.move(to: CGPoint(x: cell.midX - arm, y: cell.midY))
        context.addLine(to: CGPoint(x: cell.midX + arm, y: cell.midY))
        context.move(to: CGPoint(x: cell.midX, y: cell.midY - arm))
        context.addLine(to: CGPoint(x: cell.midX, y: cell.midY + arm))
        context.strokePath()
        context.restoreGState()
    }

    /// Where the ring sits inside this window: the usable part of the screen, in the view's own
    /// upside-down coordinates.
    private var region: CGRect {
        let appKit = Coordinates.appKit(ring.geometry.viewport)
        let origin = window?.frame.origin ?? .zero
        return CGRect(x: appKit.minX - origin.x, y: appKit.minY - origin.y,
                      width: appKit.width, height: appKit.height)
    }

    /// A row of dots along the bottom: the whole ring, and where on it you are standing.
    private func drawRingIndicator(in context: CGContext) {
        let area = region
        let geometry = ring.geometry
        let count = geometry.ringColumns
        let spacing: CGFloat = 16
        let width = CGFloat(count - 1) * spacing
        let centre = (offset + Double(geometry.visibleColumns) / 2)
            .truncatingRemainder(dividingBy: Double(count))
        for index in 0..<count {
            let x = area.midX - width / 2 + CGFloat(index) * spacing
            var distance = abs(Double(index) - centre)
            distance = min(distance, Double(count) - distance)
            let near = max(0, 1 - distance / 1.5)
            let radius: CGFloat = 2.5 + 2.5 * CGFloat(near)
            let colour = NSColor.white.withAlphaComponent(0.2 + 0.7 * CGFloat(near))
            context.setFillColor(colour.cgColor)
            context.fillEllipse(in: CGRect(x: x - radius, y: area.minY + 22 - radius,
                                           width: radius * 2, height: radius * 2))
        }
    }
}

/// The layer above the apps: the masked margins down each side, and the outline that says where
/// a dropped window will go.
final class DropMarkerView: NSView {
    var target: CGRect?
    /// In display coordinates; the strips that hide parked windows.
    var margins: [CGRect] = []

    override var isOpaque: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        for margin in margins {
            NSColor.black.setFill()
            local(Coordinates.appKit(margin)).fill()
        }
        guard var target else { return }
        // The marker window covers the glasses, so a screen rectangle has to come back to the
        // view's own corner.
        target.origin.x -= window?.frame.minX ?? 0
        target.origin.y -= window?.frame.minY ?? 0
        let path = NSBezierPath(roundedRect: target, xRadius: 16, yRadius: 16)
        NSColor.white.withAlphaComponent(0.10).setFill()
        path.fill()
        NSColor.white.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 3
        path.setLineDash([10, 7], count: 2, phase: 0)
        path.stroke()
    }

    /// A screen rectangle in this view's own coordinates.
    private func local(_ rect: CGRect) -> NSRect {
        let origin = window?.frame.origin ?? .zero
        return NSRect(x: rect.minX - origin.x, y: rect.minY - origin.y,
                      width: rect.width, height: rect.height)
    }
}
