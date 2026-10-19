// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WeblocThumbnails",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "WeblocThumbnails", targets: ["WeblocThumbnails"])],
    targets: [
        .target(name: "ThumbnailCore"),
        .executableTarget(name: "WeblocThumbnails", dependencies: ["ThumbnailCore"]),
        .testTarget(name: "ThumbnailCoreTests", dependencies: ["ThumbnailCore"])
    ]
)
