import Foundation

print("TheGrid tests")
geometryTests()
occupancyTests()
scrollTests()

if Check.failures.isEmpty {
    print("all passed")
} else {
    print("\n\(Check.failures.count) failed:")
    for f in Check.failures { print("  - \(f)") }
    exit(1)
}
