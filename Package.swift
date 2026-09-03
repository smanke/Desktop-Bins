// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "DesktopBins",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "DesktopBins",
            path: "Sources/DesktopBins"
        )
    ]
)
