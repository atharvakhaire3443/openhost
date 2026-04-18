// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenHost",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0")
    ],
    targets: [
        .executableTarget(
            name: "OpenHost",
            dependencies: [
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "Hummingbird", package: "hummingbird")
            ],
            path: "Sources/OpenHost"
        )
    ]
)
