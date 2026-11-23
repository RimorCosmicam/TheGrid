import AppKit
import ApplicationServices
import CoreGraphics
import GridCore

/// The grid, in charge.
///
/// It holds the ring, turns it when the trackpad says so, and after every change tells the mover
/// where each window belongs. Windows on the far side of the ring are parked just off the edge of
/// the glasses, so turning back to them slides them in rather than popping them up.
@MainActor
final class RingController {
    private(set) var ring: Ring
    private var scroller: RingScroller
    private let ax = AXWindows()
    private let mover = WindowMover()
    private let overlay = Overlay()
    private var settings: Settings

    /// Where each window was before the grid took it, so letting go puts it back.
    private var restore: [WindowKey: CGRect] = [:]
    private var known: [WindowKey: DeskWindow] = [:]
    /// Resolved once when a window joins the ring and refreshed by the housekeeping, never in a
    /// frame: asking an app for its windows is a round trip, and ninety of those a second to
    /// every app on the ring would stall the gesture it is meant to be following.
    private var elements: [WindowKey: AXUIElement] = [:]
    private var lastSnap: [WindowKey: Date] = [:]
    /// How many times the grid has asked a window to go somewhere it did not go. Apps refuse for
    /// their own reasons - a minimum size, a resize still in flight - and the grid tries again a
    /// few times before taking the refusal for an answer.
    private var retries: [WindowKey: Int] = [:]
    private var glasses: DisplayWatcher.Screen?
    private var ticker: DispatchSourceTimer?
    private var housekeeping: DispatchSourceTimer?
    /// The user has a window by its title bar, or by an edge. The ring keeps its hands off until
    /// they let go.
    private var isUserDragging = false
    /// The window under the pointer when it went down, and the size it was then. What the user
    /// did to it is the difference between that size and the one it has when they let go.
    private var pressed: (key: WindowKey, frame: CGRect)?
    private var statePending: DispatchWorkItem?
    private var draggedWindow: WindowKey?

    var onStateChange: () -> Void = {}

    /// The ring changed: redraw the menu, and leave the state where `--state` can read it.
    ///
    /// The state is written a moment late on purpose. Windows are moved on another thread, so
    /// reading their frames in the same breath as asking them to move catches them halfway: the
    /// new size, the old position. A fifth of a second later they have arrived.
    private func announce() {
        onStateChange()
        statePending?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.publishState() }
        statePending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: work)
    }

    init(settings: Settings) {
        self.settings = settings
        let geometry = GridGeometry(viewport: .zero,
                                    visibleColumns: settings.visibleColumns,
                                    rows: settings.rows,
                                    ringColumns: settings.ringColumns,
                                    padding: settings.padding)
        ring = Ring(geometry: geometry)
        scroller = RingScroller(ringColumns: settings.ringColumns)
    }

    /// Where the slots go: the usable screen, less the masked margin down each side that parked
    /// windows hide in.
    private func gridArea(of screen: DisplayWatcher.Screen) -> CGRect {
        screen.usable.insetBy(dx: AXWindows.minimumVisible, dy: 0)
    }

    var isActive: Bool { glasses != nil }
    var windowCount: Int { ring.windows.count }
    var column: Int { ring.geometry.wrap(column: Int(scroller.offset.rounded())) }

    func apply(settings new: Settings) {
        settings = new
        let geometry = GridGeometry(viewport: ring.geometry.viewport,
                                visibleColumns: new.visibleColumns,
                                rows: new.rows,
                                ringColumns: new.ringColumns,
                                padding: new.padding)
        ring.geometry = geometry
        scroller.ringColumns = new.ringColumns
        overlay.set(backdropOpacity: new.backdropOpacity)
        place()
    }

    // MARK: - The glasses coming and going

    func use(screen: DisplayWatcher.Screen?) {
        glasses = screen
        guard let screen else {
            releaseAll()
            overlay.hide()
            stopTicking()
            housekeeping?.cancel()
            housekeeping = nil
            announce()
            return
        }
        ring.geometry = GridGeometry(viewport: gridArea(of: screen),
                                     visibleColumns: settings.visibleColumns,
                                     rows: settings.rows,
                                     ringColumns: settings.ringColumns,
                                     padding: settings.padding)
        // The chrome covers the whole screen, so the glasses go black to the edges, and draws the
        // slots inside the part a window can reach.
        overlay.show(on: screen.bounds, usable: screen.usable)
        overlay.set(backdropOpacity: settings.backdropOpacity)
        startHousekeeping()
        place()
        announce()
    }

    // MARK: - Turning the ring

    func pan(columns: Double) {
        guard isActive else { return }
        scroller.drag(columns: columns, at: ProcessInfo.processInfo.systemUptime)
        place()
        startTicking()
    }

    func endPan() {
        guard isActive else { return }
        scroller.release()
        startTicking()
    }

    func step(_ columns: Int) {
        guard isActive else { return }
        scroller.step(columns: columns)
        startTicking()
    }

    private func startTicking() {
        guard ticker == nil else { return }
        var last = ProcessInfo.processInfo.systemUptime
        let timer = DispatchSource.makeTimerSource(queue: .main)
        // 90 a second: more than the glasses' 60, so a frame is never waiting on the timer.
        timer.schedule(deadline: .now(), repeating: 1.0 / 90, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let now = ProcessInfo.processInfo.systemUptime
            let dt = min(now - last, 0.1)
            last = now
            let moving = self.scroller.advance(by: dt)
            self.place()
            if !moving && !self.scroller.isMoving { self.stopTicking() }
        }
        ticker = timer
        timer.resume()
    }

    private func stopTicking() {
        ticker?.cancel()
        ticker = nil
        publishState()
    }

    /// Everything the ring holds, told where to be, and the chrome redrawn to match.
    /// What the ring is holding, for `TheGrid --state`: the arrangement as the ring means it,
    /// next to where the windows actually ended up, which is how you tell an app that refused a
    /// size from a grid that asked for the wrong one.
    private func publishState() {
        let geometry = ring.geometry
        var windows: [[String: Any]] = []
        for key in ring.windows {
            guard let placement = ring.placement(of: key) else { continue }
            let wanted = geometry.frame(for: placement, offset: scroller.offset)
            var entry: [String: Any] = [
                "id": Int(key),
                "app": known[key]?.app ?? "",
                "title": known[key]?.title ?? "",
                "column": placement.column,
                "row": placement.row,
                "columnSpan": placement.columnSpan,
                "rowSpan": placement.rowSpan,
                "wanted": rect(wanted),
                "onGlasses": geometry.isOnScreen(wanted),
            ]
            if let element = elements[key], let actual = ax.frame(of: element) {
                entry["actual"] = rect(actual)
            }
            windows.append(entry)
        }
        Remote.write(state: [
            "running": true,
            "active": isActive,
            "display": glasses?.name ?? "",
            "viewport": rect(geometry.viewport),
            "slot": ["width": geometry.slotSize.width, "height": geometry.slotSize.height],
            "visibleColumns": geometry.visibleColumns,
            "rows": geometry.rows,
            "ringColumns": geometry.ringColumns,
            "offset": scroller.offset,
            "column": column,
            "windows": windows,
        ])
    }

    private func rect(_ r: CGRect) -> [String: Double] {
        ["x": r.minX, "y": r.minY, "width": r.width, "height": r.height]
    }

    private func place() {
        guard isActive else { return }
        var moves: [CGWindowID: WindowMover.Move] = [:]
        for entry in ring.frames(offset: scroller.offset) {
            guard let element = elements[entry.key] else { continue }
            // A window the user is dragging goes where their hand goes.
            if isUserDragging, entry.key == draggedWindow { continue }
            moves[entry.key] = WindowMover.Move(element: element, frame: entry.frame)
        }
        mover.want(moves)
        overlay.update(ring: ring, offset: scroller.offset)
    }

    // MARK: - Getting windows in and out

    /// A window let go of over the glasses: the main gesture for putting an app on the ring.
    /// The pointer came up. What happens next depends on what the user was doing with it, and
    /// the only difference between dragging a window and resizing it is which of its size and
    /// its position changed. Letting go of an edge used to be read as a drop, which moved the
    /// window to whatever slot the pointer happened to be over: a resize that moved the window.
    func drop(at point: CGPoint) {
        overlay.markDrop(nil)
        isUserDragging = false
        draggedWindow = nil
        let grabbed = pressed
        pressed = nil
        guard isActive else { return }

        let live = ax.onScreen()
        for window in live { known[window.id] = window }
        // The window the user had hold of, which is more reliable than whatever is under the
        // pointer: a window dragged smaller may have shrunk away from under it.
        let window = grabbed.flatMap { held in live.first { $0.id == held.key } }
            ?? live.first { $0.frame.contains(point) }
        guard let window else { return }

        if let grabbed, grabbed.key == window.id, ring.placement(of: window.id) != nil,
           abs(grabbed.frame.width - window.frame.width) > 4
            || abs(grabbed.frame.height - window.frame.height) > 4 {
            resized(window)
            return
        }

        guard ring.geometry.viewport.contains(point) else {
            // Dragged off the glasses and onto the Mac: the ring lets it go, and leaves it where
            // the hand left it rather than snapping it back to where it used to live.
            if ring.placement(of: window.id) != nil { release(window.id, restoringFrame: false) }
            return
        }
        adopt(window, at: point)
    }

    /// A window let go of after being dragged by an edge: it keeps its slot and takes however
    /// many slots it now covers. Growing into a slot something else is in is refused, and the
    /// window goes back to the size of the slots it holds.
    private func resized(_ window: DeskWindow) {
        guard let placement = ring.placement(of: window.id) else { return }
        let span = ring.geometry.span(for: window.frame.size)
        var wanted = placement
        wanted.columnSpan = span.columns
        wanted.rowSpan = span.rows
        if wanted.row + wanted.rowSpan > ring.geometry.rows {
            wanted.row = ring.geometry.rows - wanted.rowSpan
        }
        retries[window.id] = 0
        lastSnap[window.id] = Date()
        mover.forget(window.id)
        if wanted != placement, ring.isFree(wanted, ignoring: window.id) {
            ring.put(window.id, at: wanted)
        }
        place()
        announce()
    }

    /// While a window is being dragged over the glasses, show where it would land.
    func dragging(at point: CGPoint) {
        guard isActive else { return }
        if !isUserDragging {
            isUserDragging = true
            // The window grabbed when the pointer went down, not whatever is under it now: a
            // resize drags an edge, and the pointer sits a point or two outside the window.
            draggedWindow = pressed?.key ?? window(at: point)?.id
        }
        guard let slot = ring.geometry.slot(at: point, offset: scroller.offset) else {
            overlay.markDrop(nil)
            return
        }
        let span = draggedWindow.flatMap { ring.placement(of: $0) }
        let placement = Placement(column: slot.column, row: slot.row,
                                  columnSpan: span?.columnSpan ?? 1,
                                  rowSpan: span?.rowSpan ?? 1)
        overlay.markDrop(ring.geometry.frame(for: placement, offset: scroller.offset))
    }

    /// The pointer went down. Remember what it landed on and how big that was, so that when it
    /// comes up the grid knows whether the window was moved or resized.
    func press(at point: CGPoint) {
        pressed = nil
        guard isActive else { return }
        // A resize starts a point or two outside the frame, where the pointer turns into an
        // arrow, so look a little wider than the window itself.
        let reach: CGFloat = 6
        guard let window = ax.onScreen().first(where: {
            $0.frame.insetBy(dx: -reach, dy: -reach).contains(point)
        }) else { return }
        known[window.id] = window
        pressed = (window.id, window.frame)
        if ring.placement(of: window.id) != nil { ring.raise(window.id) }
    }

    private func adopt(_ window: DeskWindow, at point: CGPoint) {
        guard let slot = ring.geometry.slot(at: point, offset: scroller.offset) else { return }
        known[window.id] = window
        let existing = ring.placement(of: window.id)
        let span = existing.map { (columns: $0.columnSpan, rows: $0.rowSpan) }
            ?? ring.geometry.span(for: window.frame.size)
        var wanted = Placement(column: slot.column, row: slot.row,
                               columnSpan: span.columns, rowSpan: span.rows)
        // A window two rows tall dropped on the bottom row sits in the top one instead; there is
        // nowhere below it to grow.
        if wanted.row + wanted.rowSpan > ring.geometry.rows {
            wanted.row = ring.geometry.rows - wanted.rowSpan
        }
        guard let placement = ring.nearestFree(to: wanted, ignoring: window.id)
                ?? ring.nearestFree(to: Placement(column: slot.column, row: slot.row),
                                    ignoring: window.id) else { return }
        guard let element = ax.element(for: window) else { return }
        elements[window.id] = element
        if existing == nil { restore[window.id] = window.frame }
        retries[window.id] = 0
        mover.forget(window.id)
        ring.put(window.id, at: placement)
        place()
        announce()
    }

    /// The window in front on the Mac's own screen, onto the first free slot. With a name, that
    /// app's front window instead.
    func pullInFrontWindow(matching app: String? = nil) {
        guard isActive else { return }
        let windows = ax.onScreen().filter { window in
            guard ring.placement(of: window.id) == nil else { return false }
            guard let app else { return true }
            return window.app.localizedCaseInsensitiveContains(app)
        }
        guard let window = windows.first else { return }
        guard let slot = ring.firstFree(near: scroller.offset,
                                       span: ring.geometry.span(for: window.frame.size))
                ?? ring.firstFree(near: scroller.offset) else { return }
        guard let element = ax.element(for: window) else { return }
        known[window.id] = window
        elements[window.id] = element
        restore[window.id] = window.frame
        mover.forget(window.id)
        ring.put(window.id, at: slot)
        place()
        announce()
    }

    /// Takes a window off the ring. `restoringFrame` puts it back the size and place it was
    /// before the grid took it, which is what unplugging the glasses or the menu item should do;
    /// a window the user has just dragged onto the Mac's screen stays where they dropped it.
    func release(_ key: WindowKey, restoringFrame: Bool = true) {
        ring.remove(key)
        mover.forget(key)
        if restoringFrame, let frame = restore[key], let element = elements[key] {
            ax.setFrame(frame, of: element)
        }
        restore[key] = nil
        known[key] = nil
        elements[key] = nil
        ax.forget(key)
        place()
        announce()
    }

    func releaseAll() {
        for key in ring.windows { release(key) }
        overlay.markDrop(nil)
        announce()
    }

    private func window(at point: CGPoint) -> DeskWindow? {
        let windows = ax.onScreen()
        for window in windows { known[window.id] = window }
        return windows.first { $0.frame.contains(point) }
    }

    // MARK: - Keeping up with the user

    /// Twice a second: windows that have closed leave the ring, and a window the user has resized
    /// by its edge snaps to the number of slots it is nearest.
    private func startHousekeeping() {
        housekeeping?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tidy() }
        housekeeping = timer
        timer.resume()
    }

    private func tidy() {
        guard isActive else { return }
        let live = ax.onScreen()
        var byID: [WindowKey: DeskWindow] = [:]
        for window in live { byID[window.id] = window }
        var changed = false

        for key in ring.windows {
            guard let window = byID[key] else {
                // Closed, or minimised out of the window list: off the ring, and nothing to put
                // back, because it is not there to put.
                ring.remove(key)
                known[key] = nil
                restore[key] = nil
                elements[key] = nil
                ax.forget(key)
                changed = true
                continue
            }
            known[key] = window
            // Apps replace their Accessibility windows now and then, a tab torn off or a
            // document reopened: pick up the new handle rather than pushing at a dead one.
            if elements[key] == nil { elements[key] = ax.element(for: window) }
            if !scroller.isMoving && !isUserDragging, insist(on: key, is: window) { changed = true }
            if !scroller.isMoving && !isUserDragging { snapIfResized(window) }
        }

        if changed {
            place()
            announce()
        }
    }

    /// A window that did not go where it was put, asked again.
    ///
    /// The first attempt can fail for honest reasons: the app was busy laying out the resize it
    /// had just been given, or it clamped the window to the screen it was still on. Once it has
    /// landed on the glasses the same instruction usually works. Three tries, then the grid
    /// leaves it alone rather than fighting an app that has its own ideas about its minimum size.
    private func insist(on key: WindowKey, is window: DeskWindow) -> Bool {
        guard let placement = ring.placement(of: key) else { return false }
        let wanted = ring.geometry.frame(for: placement, offset: scroller.offset)
        let off = max(abs(window.frame.minX - wanted.minX), abs(window.frame.minY - wanted.minY),
                      abs(window.frame.width - wanted.width),
                      abs(window.frame.height - wanted.height))
        guard off > 2 else {
            retries[key] = 0
            return false
        }
        guard (retries[key] ?? 0) < 3 else { return false }
        retries[key] = (retries[key] ?? 0) + 1
        mover.forget(key)
        place()
        return false
    }

    /// A window dragged wider or taller by its edge takes the slots it now covers. Only a change
    /// of real size counts, and only one snap a second per window, so that an app arguing about
    /// its minimum size cannot start a tug of war.
    private func snapIfResized(_ window: DeskWindow) {
        guard let placement = ring.placement(of: window.id) else { return }
        let wanted = ring.geometry.frame(for: placement, offset: scroller.offset)
        let dw = abs(window.frame.width - wanted.width)
        let dh = abs(window.frame.height - wanted.height)
        guard dw > 40 || dh > 40 else { return }
        // Still being argued about by the app, not dragged by the user.
        guard (retries[window.id] ?? 0) == 0 else { return }
        if let last = lastSnap[window.id], Date().timeIntervalSince(last) < 1 { return }
        let span = ring.geometry.span(for: window.frame.size)
        var snapped = placement
        snapped.columnSpan = span.columns
        snapped.rowSpan = span.rows
        if snapped.row + snapped.rowSpan > ring.geometry.rows {
            snapped.row = ring.geometry.rows - snapped.rowSpan
        }
        guard snapped != placement else {
            // The user has dragged it off its slot's size but not far enough to change span:
            // put it back to the size of the slots it holds.
            lastSnap[window.id] = Date()
            mover.forget(window.id)
            place()
            return
        }
        guard ring.isFree(snapped, ignoring: window.id) else {
            lastSnap[window.id] = Date()
            mover.forget(window.id)
            place()
            return
        }
        lastSnap[window.id] = Date()
        ring.put(window.id, at: snapped)
        mover.forget(window.id)
        place()
        announce()
    }
}
