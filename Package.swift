// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "OpenNotebook",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "OpenNotebook",
            targets: ["OpenNotebook"]
        )
    ],
    targets: [
        .executableTarget(
            name: "OpenNotebook",
            path: "Sources/OpenNotebook"
        ),
        .testTarget(
            name: "OpenNotebookTests",
            dependencies: ["OpenNotebook"],
            path: "Tests/OpenNotebookTests"
        )
    ]
)
