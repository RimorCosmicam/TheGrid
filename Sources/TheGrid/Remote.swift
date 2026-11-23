import AppKit
import GridCore

/// Driving the grid from outside it.
///
/// The menu bar is the way to use TheGrid, but not the way to test it: a gesture and a menu both
/// need a hand. These commands do the same things from a terminal, so the ring can be put through
/// its paces and asked what it did. They are also the hook a keyboard shortcut or a Shortcuts
/// action would use.
///
///     TheGrid --pull            the front window onto the ring
///     TheGrid --pull Safari     that app's front window instead
///     TheGrid --turn 2          two slots to the right, -2 for left
///     TheGrid --release         every window back where it was
///     TheGrid --state           what the ring is holding, as JSON
enum Remote {
    static let pull = "com.thegrid.pull"
    static let turn = "com.thegrid.turn"
    static let release = "com.thegrid.release"

    /// Where the running app leaves its state for `--state` to read. A file rather than a reply,
    /// because a notification has nowhere to put an answer.
    static var stateFile: URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask)[0]
            .appendingPathComponent("TheGrid", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        return support.appendingPathComponent("state.json")
    }

    /// Handles a command and returns true if the process was only here to send one.
    static func handleCommandLine() -> Bool {
        let arguments = CommandLine.arguments
        let centre = DistributedNotificationCenter.default()
        if let index = arguments.firstIndex(of: "--pull") {
            // A name after it picks that app's window rather than whatever is in front, which is
            // what you want when the window in front is the one you are reading.
            let app = arguments.count > index + 1 && !arguments[index + 1].hasPrefix("-")
                ? arguments[index + 1] : nil
            centre.postNotificationName(.init(pull), object: app, userInfo: nil,
                                        deliverImmediately: true)
            return true
        }
        if let index = arguments.firstIndex(of: "--turn") {
            let columns = arguments.count > index + 1 ? arguments[index + 1] : "1"
            centre.postNotificationName(.init(turn), object: columns, userInfo: nil,
                                        deliverImmediately: true)
            return true
        }
        if arguments.contains("--release") {
            centre.postNotificationName(.init(release), object: nil, userInfo: nil,
                                        deliverImmediately: true)
            return true
        }
        if arguments.contains("--state") {
            if let data = try? Data(contentsOf: stateFile),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            } else {
                print("{\"running\": false}")
            }
            return true
        }
        return false
    }

    /// The running app's answer to `--state`, written whenever the ring changes.
    static func write(state: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: state,
                                                     options: [.prettyPrinted, .sortedKeys]) else {
            return
        }
        try? data.write(to: stateFile)
    }
}
