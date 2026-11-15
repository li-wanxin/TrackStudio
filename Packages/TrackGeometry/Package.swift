// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "TrackGeometry",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TrackGeometry", targets: ["TrackGeometry"])
    ],
    targets: [
        .target(
            name: "TrackGeometry",
            resources: [.process("Resources/parts_seed.json")]
        ),
        .testTarget(
            name: "TrackGeometryTests",
            dependencies: ["TrackGeometry"]
        )
    ]
)
