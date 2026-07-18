// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "avc",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.3.0"),
        .package(url: "https://github.com/swiftlang/swift-testing", from: "0.12.0"),
    ],
    targets: [
        .executableTarget(
            name: "avc",
            dependencies: [.product(name: "ArgumentParser", package: "swift-argument-parser")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "avcTests",
            dependencies: ["avc", .product(name: "Testing", package: "swift-testing")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
