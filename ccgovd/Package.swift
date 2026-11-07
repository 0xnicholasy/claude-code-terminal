// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "ccgovd",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CCGovCore", targets: ["CCGovCore"]),
        .executable(name: "ccgovd", targets: ["ccgovd"]),
    ],
    dependencies: [
        .package(path: "../Protocol"),
    ],
    targets: [
        .target(
            name: "CCGovCore",
            dependencies: [.product(name: "CCProtocol", package: "Protocol")]
        ),
        .executableTarget(name: "ccgovd", dependencies: ["CCGovCore"]),
        .testTarget(name: "CCGovCoreTests", dependencies: ["CCGovCore"]),
    ],
    // The daemon is thread-based (POSIX socket threads + one serial queue); Swift 5 mode avoids
    // Sendable annotations on every closure without changing runtime behaviour.
    swiftLanguageModes: [.v5]
)
