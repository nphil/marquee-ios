// swift-tools-version: 6.2
import PackageDescription

// The engine's FFmpeg ships iOS slices only, so the tests run on an iOS simulator (xcodebuild), not `swift test`.
let ffmpeg: Target.Dependency = .product(name: "FFmpeg", package: "stashy-videoengine")

let package = Package(
    name: "MarqueeLive",
    platforms: [.iOS("27.0")],
    products: [
        .library(name: "MarqueeLive", targets: ["MarqueeLive", "LiveEngine"]),
        // The app's debug builds play it in UI tests and screenshots.
        .library(name: "LiveFixtures", targets: ["LiveFixtures"]),
    ],
    dependencies: [
        // The same pin as the app's VideoEngine, so both resolve to one checkout.
        .package(url: "https://github.com/nphil/stashy-videoengine.git", exact: "2.0.1"),
    ],
    targets: [
        // Platform-neutral: no AVFoundation, so a scratch package can test it on Linux.
        .target(name: "LiveEngine", dependencies: [ffmpeg]),
        .target(name: "LiveFixtures", dependencies: ["LiveEngine", ffmpeg]),
        .target(name: "MarqueeLive", dependencies: ["LiveEngine", ffmpeg]),
        .testTarget(name: "LiveEngineTests", dependencies: ["LiveEngine", "LiveFixtures", ffmpeg]),
        .testTarget(name: "MarqueeLiveTests", dependencies: ["MarqueeLive", "LiveEngine", "LiveFixtures", ffmpeg]),
    ]
)
