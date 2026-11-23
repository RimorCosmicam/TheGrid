// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TheGrid",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "GridCore", targets: ["GridCore"]),
        .executable(name: "TheGrid", targets: ["TheGrid"]),
    ],
    targets: [
        // The ring itself: where every slot sits, which ones are taken, and how a flick of the
        // trackpad turns into a glide from slot to slot. No AppKit and no Accessibility, so it
        // runs in the tests on any Mac, with no windows and no glasses.
        .target(name: "GridCore"),

        // The app: a menu bar item that moves the Mac's real windows around the ring.
        .executableTarget(name: "TheGrid", dependencies: ["GridCore"]),

        // An executable rather than a .testTarget: XCTest needs Xcode, and this machine has only
        // the Command Line Tools. A plain binary that exits non-zero runs the same here and in CI.
        .executableTarget(name: "gridtests", dependencies: ["GridCore"]),
    ]
)
