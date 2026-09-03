// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopFences",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DesktopFences",
            path: "Sources/DesktopFences"
        )
    ]
)
