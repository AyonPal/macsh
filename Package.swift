// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MacshCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MacshCore", targets: ["MacshCore"]),
    ],
    targets: [
        .target(
            name: "MacshCore",
            path: "Sources/MacshCore",
            linkerSettings: [
                .linkedFramework("NetFS"),
            ]
        ),
        .testTarget(
            name: "MacshCoreTests",
            dependencies: ["MacshCore"],
            path: "Tests/MacshCoreTests"
        ),
    ]
)
