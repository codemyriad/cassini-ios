// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Cassini",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "CassiniCore", targets: ["CassiniCore"]),
        .library(name: "CassiniNotebook", targets: ["CassiniNotebook"])
    ],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "CassiniCore", dependencies: ["CZlib"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CassiniCoreTests", dependencies: ["CassiniCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CassiniNotebook", dependencies: ["CassiniCore"], path: "Packages/CassiniNotebook/Sources/CassiniNotebook"),
        .testTarget(name: "CassiniNotebookTests", dependencies: ["CassiniNotebook", "CassiniCore"], path: "Packages/CassiniNotebook/Tests/CassiniNotebookTests")
    ]
)
