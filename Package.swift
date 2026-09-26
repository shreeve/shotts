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
        .target(name: "ShottsUI", dependencies: ["ShottsCore"]),
        .executableTarget(name: "Shotts", dependencies: ["ShottsUI", "ShottsCore"]),
        .testTarget(name: "ShottsCoreTests", dependencies: ["ShottsCore"]),
    ]
)
