import AppKit
import ApplicationServices
import CoreGraphics

/// Puts windows where the ring says they belong, as fast as the apps can take it.
///
/// Every Accessibility call is a round trip to another app, and one slow app would freeze the
/// gesture if the ring waited for it. So the ring only ever says where windows should be; this
/// applies it on its own thread, keeps the newest answer for each window and drops the ones
/// overtaken while an app was thinking. A scroll that sets sixty positions a second to an app
/// that can manage twenty simply skips the forty nobody would have seen.
final class WindowMover {
    struct Move {
        var element: AXUIElement
        var frame: CGRect
    }

    private let queue = DispatchQueue(label: "thegrid.mover", qos: .userInteractive)
    private let lock = NSLock()
    private let ax = AXWindows()
    private var wanted: [CGWindowID: Move] = [:]
    private var applied: [CGWindowID: CGRect] = [:]
    private var running = false

    /// The whole arrangement, as of this frame. Windows left out are left alone.
    func want(_ moves: [CGWindowID: Move]) {
        lock.lock()
        for (id, move) in moves { wanted[id] = move }
        let shouldStart = !running
        if shouldStart { running = true }
        lock.unlock()
        if shouldStart { queue.async { [weak self] in self?.drain() } }
    }

    /// Forgets where a window was, so the next want() is sent even if it matches: for windows the
    /// user has since moved themselves.
    func forget(_ id: CGWindowID) {
        lock.lock()
        applied[id] = nil
        wanted[id] = nil
        lock.unlock()
    }

    /// What the mover last told the system, for telling our own moves from the user's.
    func lastApplied(_ id: CGWindowID) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        return applied[id]
    }

    private func drain() {
        while true {
            lock.lock()
            let work = wanted
            wanted = [:]
            if work.isEmpty {
                running = false
                lock.unlock()
                return
            }
            let before = applied
            lock.unlock()

            var done: [CGWindowID: CGRect] = [:]
            for (id, move) in work {
                let frame = move.frame
                let old = before[id]
                if let old, same(old, frame) { continue }
                if let old, abs(old.width - frame.width) < 0.75,
                   abs(old.height - frame.height) < 0.75 {
                    // Sliding round the ring: position only, one call instead of three.
                    ax.setPosition(frame.origin, of: move.element)
                } else {
                    ax.setFrame(frame, of: move.element)
                }
                done[id] = frame
            }

            lock.lock()
            for (id, frame) in done { applied[id] = frame }
            lock.unlock()
        }
    }

    /// A move of less than a point is below what any screen can show.
    private func same(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.origin.x - b.origin.x) < 0.75 && abs(a.origin.y - b.origin.y) < 0.75
            && abs(a.width - b.width) < 0.75 && abs(a.height - b.height) < 0.75
    }
}
