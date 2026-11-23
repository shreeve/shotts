// swift-tools-version: 6.4

import PackageDescription

// A warning is a build failure.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
    name: "Switcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "shotts-switcher", targets: ["shotts-switcher"]),
    ],
    targets: [
        // The decisions, with tests: no AppKit, no events.
        .target(name: "SwitcherCore", swiftSettings: strict),
        // The program: listens for the swipe and Control-arrow, posts the switch.
        .executableTarget(name: "shotts-switcher", dependencies: ["SwitcherCore"],
                          swiftSettings: strict + [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "SwitcherCoreTests", dependencies: ["SwitcherCore"], swiftSettings: strict),
    ]
)
