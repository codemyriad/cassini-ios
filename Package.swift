// swift-tools-version:5.5
import PackageDescription

let package = Package(
    name: "CassiniCore",
    platforms: [.iOS(.v15), .macOS(.v10_15)],
    products: [.library(name: "CassiniCore", targets: ["CassiniCore"])],
    targets: [
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(name: "CassiniCore", dependencies: ["CZlib"]),
        .testTarget(name: "CassiniCoreTests", dependencies: ["CassiniCore"]),
    ]
)
