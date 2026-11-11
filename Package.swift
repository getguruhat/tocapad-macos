// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TocaPad",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "TocaPad", path: "Sources/TocaPad"),
    ]
)
