// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MarqueeCore",
    platforms: [
        .iOS("27.0"),
        // macOS only so `swift test` runs on the CI host.
        .macOS("27.0"),
    ],
    products: [
        .library(name: "MarqueeCore", targets: ["MarqueeCore"]),
    ],
    targets: [
        .target(name: "MarqueeCore"),
        .testTarget(name: "MarqueeCoreTests", dependencies: ["MarqueeCore"]),
    ]
)
