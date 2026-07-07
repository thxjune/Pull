// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pull",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Pull",
            path: "Sources/Pull"
        )
    ]
)
