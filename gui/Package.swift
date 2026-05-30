// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "CloudnetipSPN",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "CloudnetipSPN",
            path: "Sources/CloudnetipSPN"
        )
    ]
)
