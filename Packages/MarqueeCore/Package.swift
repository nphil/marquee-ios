// swift-tools-version: 6.2
import PackageDescription

var packageDependencies: [Package.Dependency] = []
var coreDependencies: [Target.Dependency] = []
#if os(Linux)
// CryptoKit is Apple-only. On Linux the link keys build against swift-crypto, which has the same API,
// so the Core tests run on any host.
packageDependencies.append(.package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"))
coreDependencies.append(.product(name: "Crypto", package: "swift-crypto"))
#endif

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
    dependencies: packageDependencies,
    targets: [
        .target(name: "MarqueeCore", dependencies: coreDependencies),
        .testTarget(name: "MarqueeCoreTests", dependencies: ["MarqueeCore"]),
    ]
)
