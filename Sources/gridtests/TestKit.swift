import Foundation

/// A test harness small enough to need no framework: count the failures, print them, exit non-zero.
enum Check {
    static var failures: [String] = []

    static func that(_ condition: Bool, _ what: String,
                     file: StaticString = #file, line: UInt = #line) {
        if !condition { failures.append("\(short(file)):\(line) \(what)") }
    }

    static func equal<T: Equatable>(_ a: T, _ b: T, _ what: String,
                                    file: StaticString = #file, line: UInt = #line) {
        if a != b { failures.append("\(short(file)):\(line) \(what): \(a) != \(b)") }
    }

    static func close(_ a: Double, _ b: Double, _ what: String, tolerance: Double = 0.001,
                      file: StaticString = #file, line: UInt = #line) {
        if abs(a - b) > tolerance { failures.append("\(short(file)):\(line) \(what): \(a) != \(b)") }
    }

    private static func short(_ file: StaticString) -> String {
        (("\(file)" as NSString).lastPathComponent)
    }
}

func run(_ name: String, _ body: () -> Void) {
    let before = Check.failures.count
    body()
    let added = Check.failures.count - before
    print(added == 0 ? "  ok  \(name)" : "  FAIL \(name) (\(added))")
}
