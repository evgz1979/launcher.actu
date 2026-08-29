// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Launcher",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Launcher", targets: ["Launcher"])
    ],
    targets: [
        .executableTarget(name: "Launcher"),
        .testTarget(name: "LauncherTests", dependencies: ["Launcher"])
    ]
)
