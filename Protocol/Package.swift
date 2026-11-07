// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CCProtocol",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CCProtocol", targets: ["CCProtocol"]),
    ],
    targets: [
        .target(name: "CCProtocol"),
        .testTarget(name: "CCProtocolTests", dependencies: ["CCProtocol"]),
    ]
)
