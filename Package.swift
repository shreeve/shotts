// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "Shotts",
    platforms: [
        .macOS(.v27)
    ],
    products: [
        .executable(name: "Shotts", targets: ["Shotts"])
    ],
    targets: [
        .target(name: "ShottsCore"),
        .target(name: "ShottsUI", dependencies: ["ShottsCore"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .executableTarget(name: "Shotts", dependencies: ["ShottsUI", "ShottsCore"], swiftSettings: [.defaultIsolation(MainActor.self)]),
        .testTarget(name: "ShottsCoreTests", dependencies: ["ShottsCore"]),
    ]
)
