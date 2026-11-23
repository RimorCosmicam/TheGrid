import AppKit
import CoreGraphics

/// The trackpad, read from outside every app.
///
/// Three fingers on the pad turn the ring. macOS has its own plans for three fingers, so there
/// are two ways in and both are watched at once:
///
/// - The touches themselves, from a global monitor. This is the gesture the user asked for, and
///   it needs "Swipe between full-screen applications" set to four fingers in Trackpad settings,
///   or macOS switches Spaces at the same time.
/// - Option held with an ordinary scroll, caught in an event tap and swallowed so that whatever
///   is under the pointer does not scroll as well. This one always works.
///
/// Control-Option-Left and Right step one slot at a time, for when neither hand is on the pad.
final class GestureReader {
    /// Turn the ring by this many slots.
    var onPan: (Double) -> Void = { _ in }
    /// The fingers lifted: settle onto a slot.
    var onPanEnd: () -> Void = {}
    /// Jump a whole slot.
    var onStep: (Int) -> Void = { _ in }
    /// A window was being dragged and has just been let go here, in screen coordinates.
    var onDrop: (CGPoint) -> Void = { _ in }
    /// The pointer went down here: the start of a drag, or a click on a window in the grid.
    var onPress: (CGPoint) -> Void = { _ in }
    /// A window is being dragged and the pointer is here now.
    var onDrag: (CGPoint) -> Void = { _ in }

    var settings: Settings

    private var monitors: [Any] = []
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var lastTouchCentre: CGPoint?
    private var pressPoint: CGPoint?
    private var dragged = false
    private var touchEndWork: DispatchWorkItem?
    private var lastTouchCount = -1

    init(settings: Settings) {
        self.settings = settings
    }

    func start() {
        stop()
        let mask: NSEvent.EventTypeMask = [
            .gesture, .beginGesture, .endGesture, .swipe, .scrollWheel,
            .leftMouseDown, .leftMouseDragged, .leftMouseUp,
            .keyDown,
        ]
        if let monitor = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] in
            self?.handle($0)
        }) {
            monitors.append(monitor)
        }
        startTap()
    }

    func stop() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        tapSource = nil
        tap = nil
    }

    // MARK: - Touches

    private func handle(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            pressPoint = event.cgLocation
            dragged = false
            onPress(event.cgLocation)
        case .leftMouseDragged:
            if let start = pressPoint, hypot(event.cgLocation.x - start.x,
                                             event.cgLocation.y - start.y) > 16 {
                dragged = true
            }
            if dragged { onDrag(event.cgLocation) }
        case .leftMouseUp:
            if dragged { onDrop(event.cgLocation) }
            pressPoint = nil
            dragged = false
        case .keyDown:
            handleKey(event)
        default:
            if settings.gesture.allowsTouches { handleTouches(event) }
        }
    }

    private func handleKey(_ event: NSEvent) {
        let wanted: NSEvent.ModifierFlags = [.control, .option]
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == wanted else { return }
        switch event.keyCode {
        case 123: onStep(-1)   // left arrow
        case 124: onStep(1)    // right arrow
        default: break
        }
    }

    /// Three fingers resting on the pad, wherever they came from: a gesture event, or a scroll
    /// that happens to carry three touches. The ring follows the middle of them.
    private func handleTouches(_ event: NSEvent) {
        let touches = event.touches(matching: .touching, in: nil)
        if settings.logsGestures, touches.count != lastTouchCount {
            lastTouchCount = touches.count
            print("[grid] \(touches.count) finger(s) on the pad, from a \(name(of: event.type)) event")
        }
        guard touches.count == 3 else {
            if lastTouchCentre != nil { endTouches() }
            return
        }
        var sum = CGPoint.zero
        for touch in touches {
            sum.x += touch.normalizedPosition.x
            sum.y += touch.normalizedPosition.y
        }
        let centre = CGPoint(x: sum.x / 3, y: sum.y / 3)
        defer { lastTouchCentre = centre }
        guard let last = lastTouchCentre else { return }
        let dx = centre.x - last.x
        // A jump of half the pad is a finger lifting and landing again, not a swipe.
        guard abs(dx) < 0.5 else { return }
        let columns = dx * settings.columnsPerSwipe * (settings.naturalDirection ? -1 : 1)
        if settings.logsGestures {
            print("[grid] three fingers dx \(String(format: "%.4f", dx)) -> \(String(format: "%.3f", columns)) columns")
        }
        onPan(columns)
        // Touch events stop arriving the moment the fingers lift, with nothing to say so.
        touchEndWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.endTouches() }
        touchEndWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    /// Event types have numbers in the log, not names, unless something says what they are.
    private func name(of type: NSEvent.EventType) -> String {
        switch type.rawValue {
        case 29: return "gesture"
        case 30: return "magnify"
        case 31: return "swipe"
        case 19: return "begin gesture"
        case 20: return "end gesture"
        case 22: return "scroll wheel"
        default: return "type \(type.rawValue)"
        }
    }

    private func endTouches() {
        touchEndWork?.cancel()
        touchEndWork = nil
        guard lastTouchCentre != nil else { return }
        lastTouchCentre = nil
        onPanEnd()
    }

    // MARK: - Option and scroll

    private func startTap() {
        var mask: CGEventMask = 0
        if settings.gesture.allowsOptionScroll {
            mask |= 1 << CGEventType.scrollWheel.rawValue
        }
        if settings.gesture.allowsTouches {
            // 29 and 31 are NSEventTypeGesture and NSEventTypeSwipe, which CGEventType has no
            // names for. A tap sees them on their way through the window server, which is a
            // surer thing than a global monitor: the monitor only gets what the system decides
            // to pass on. Both paths end in the same place, and a second look at the same event
            // moves the ring by nothing, so there is no harm in watching twice.
            mask |= (1 << 29) | (1 << 31)
        }
        guard mask != 0 else { return }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap,
                                          place: .headInsertEventTap,
                                          options: .defaultTap,
                                          eventsOfInterest: mask,
                                          callback: { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let reader = Unmanaged<GestureReader>.fromOpaque(context).takeUnretainedValue()
            return reader.tapped(type: type, event: event)
        }, userInfo: me) else {
            print("[grid] no event tap: Accessibility permission is needed for option-scroll")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.tapSource = source
    }

    private func tapped(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switches a tap off if it ever takes too long. Switch it back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type.rawValue == 29 || type.rawValue == 31 {
            if settings.gesture.allowsTouches, let touched = NSEvent(cgEvent: event) {
                handleTouches(touched)
            }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel, event.flags.contains(.maskAlternate) else {
            return Unmanaged.passUnretained(event)
        }
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)
        // Sideways if that is the bigger movement, otherwise up and down: a ring turns either way
        // and the trackpad makes vertical scrolling the easier of the two.
        let delta = abs(dx) >= abs(dy) ? dx : dy
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase)
        if settings.logsGestures {
            print("[grid] option scroll \(delta) phase \(phase) momentum \(momentum)")
        }
        if delta != 0 {
            let columns = -delta / settings.pixelsPerColumn * (settings.naturalDirection ? 1 : -1)
            DispatchQueue.main.async { [weak self] in self?.onPan(columns) }
        }
        // Phase 4 is NSEvent.Phase.ended; the momentum that follows a flick is ignored, because
        // the ring has momentum of its own.
        if phase == 4 || momentum == 4 {
            DispatchQueue.main.async { [weak self] in self?.onPanEnd() }
        }
        return nil
    }
}

extension NSEvent {
    /// The pointer in the coordinates Accessibility and the window list use: origin top left of
    /// the main screen, y downwards. AppKit hands out the other kind.
    var cgLocation: CGPoint {
        let point = locationInWindow
        guard window == nil else { return point }
        guard let main = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first else { return point }
        return CGPoint(x: point.x, y: main.frame.height - point.y)
    }
}
