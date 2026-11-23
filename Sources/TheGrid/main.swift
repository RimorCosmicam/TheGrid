import AppKit

// A menu bar app with no window of its own: everything it shows is on the glasses, and
// everything you see there is some other app's window, moved.
//
// Top level code runs on the main thread, which is where AppKit insists on being; the compiler
// wants that said out loud.
// Run from a terminal with the log on, the output goes to a pipe, and a pipe is buffered by the
// block: the lines sit in memory until there are four thousand of them. Line by line instead, so
// a gesture shows up as it happens.
setvbuf(stdout, nil, _IOLBF, 0)

MainActor.assumeIsolated {
    let app = NSApplication.shared
    if CommandLine.arguments.contains("--doctor") {
        Doctor.report()
        exit(0)
    }
    // A command for the copy already running, not a new grid.
    if Remote.handleCommandLine() { exit(0) }
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    // Held for as long as the app runs: NSApplication does not retain its delegate.
    objc_setAssociatedObject(app, Unmanaged.passUnretained(delegate).toOpaque(), delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
