// swift-tools-version: 6.4

import PackageDescription

// A warning is a build failure: there is no CI to catch one later.
let strict: [SwiftSetting] = [.treatAllWarnings(as: .error)]
let app: [SwiftSetting] = strict + [.defaultIsolation(MainActor.self)]

let package = Package(
    name: "Shotts",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Shotts", targets: ["Shotts"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0")
    ],
    targets: [
        .target(name: "ShottsCore", swiftSettings: strict),
        .target(name: "ShottsUI", dependencies: ["ShottsCore"], swiftSettings: app),
        .executableTarget(
            name: "Shotts",
            dependencies: ["ShottsUI", "ShottsCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: app
        ),
        .testTarget(name: "ShottsCoreTests", dependencies: ["ShottsCore"], path: "Tests/Core", swiftSettings: strict),
        // AppKit in windows that are never shown: the editor, the renderer, and the picker.
        .testTarget(name: "ShottsUITests", dependencies: ["ShottsUI", "ShottsCore"], path: "Tests/UI", swiftSettings: app),
    ]
)
