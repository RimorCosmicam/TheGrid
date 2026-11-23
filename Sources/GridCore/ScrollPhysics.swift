import Foundation

/// The feel of the ring turning: it follows the fingers exactly, keeps going when they lift, and
/// settles onto a slot instead of stopping wherever the flick ran out.
///
/// The position is in columns, so 1.0 is one slot across whatever the slots measure; the app only
/// has to divide pixels by the slot width.
public struct RingScroller: Sendable {
    /// Columns from the start of the ring to the left edge of the view. Not wrapped while a glide
    /// is in flight, so the spring has somewhere to travel; wrapped once it comes to rest.
    public var offset: Double = 0
    /// Columns per second.
    public var velocity: Double = 0
    public private(set) var target: Double = 0
    public private(set) var isSettling = false
    private var isDragging = false
    private var lastDragTime: TimeInterval = 0

    /// How much of the flick carries on after the fingers lift, in seconds of travel.
    public var projection: Double = 0.18
    /// At most this many slots per flick, so a hard swipe does not spin the ring blindly.
    public var maxFlingColumns = 3
    /// Stiffness of the settle, in radians per second. Damped exactly critically: it arrives and
    /// stops, with no bounce.
    public var stiffness: Double = 15

    public var ringColumns: Int

    public init(ringColumns: Int = 12, offset: Double = 0) {
        self.ringColumns = max(1, ringColumns)
        self.offset = offset
        self.target = offset
    }

    /// Fingers moved. `columns` is the movement in slots; dragging sideways by one slot's width
    /// brings the next slot fully into view.
    public mutating func drag(columns: Double, at time: TimeInterval) {
        if !isDragging {
            isDragging = true
            lastDragTime = time
            velocity = 0
        }
        isSettling = false
        offset += columns
        let dt = time - lastDragTime
        if dt > 0.0005 {
            // Smoothed, so one stuttering frame of trackpad data does not throw the flick.
            let instant = columns / dt
            velocity = velocity * 0.7 + instant * 0.3
        }
        lastDragTime = time
    }

    /// Fingers lifted: pick the slot the flick was heading for and glide to it.
    public mutating func release() {
        isDragging = false
        let projected = offset + velocity * projection
        let nearest = projected.rounded()
        let limit = Double(maxFlingColumns)
        target = min(max(nearest, offset.rounded() - limit), offset.rounded() + limit)
        isSettling = true
    }

    /// Jump the ring by whole slots, for a keyboard shortcut or a menu item. Caught halfway
    /// between two slots it goes to the next one along in that direction rather than counting
    /// from the nearest, which is what "one more" means with the ring already in motion.
    public mutating func step(columns: Int) {
        isDragging = false
        velocity = 0
        guard columns != 0 else { return }
        let atRest = abs(offset - offset.rounded()) < 0.01
        if atRest {
            target = offset.rounded() + Double(columns)
        } else {
            let next = columns > 0 ? offset.rounded(.up) : offset.rounded(.down)
            target = next + Double(columns - (columns > 0 ? 1 : -1))
        }
        isSettling = true
    }

    /// Advances the glide. Returns false once the ring is at rest and nothing needs redrawing.
    @discardableResult
    public mutating func advance(by dt: TimeInterval) -> Bool {
        guard isSettling, dt > 0 else { return isDragging }
        // A critically damped spring, stepped semi-implicitly so large frames stay stable.
        let w = stiffness
        let x = offset - target
        velocity += (-w * w * x - 2 * w * velocity) * dt
        offset += velocity * dt
        if abs(offset - target) < 0.0008 && abs(velocity) < 0.02 {
            offset = target
            velocity = 0
            isSettling = false
            normalise()
            return false
        }
        return true
    }

    public var isMoving: Bool { isDragging || isSettling }

    /// Keeps the offset inside one turn of the ring, so it never drifts into numbers too big to
    /// hold precisely. Only ever called at rest, where the jump cannot be seen.
    public mutating func normalise() {
        let n = Double(ringColumns)
        var o = offset.truncatingRemainder(dividingBy: n)
        if o < 0 { o += n }
        offset = o
        target = o
    }
}
