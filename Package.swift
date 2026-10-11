// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cassini",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "CassiniCore", targets: ["CassiniCore"]),
        .library(name: "CassiniNotebook", targets: ["CassiniNotebook"]),
        .library(name: "CassiniInference", targets: ["CassiniInference"]),
        .library(name: "CassiniAudio", targets: ["CassiniAudio"])
    ],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "e560c6445ffdc42e60c7b282d162aae271f18e2a", traits: []),
        .package(url: "https://github.com/alta/swift-opus.git", revision: "6f3cb6bd3ffed1fe5f06d00a962d5c191a50daf8")],
    targets: [
        .testTarget(name: "CassiniAudioTests", dependencies: ["CassiniAudio", "CassiniCore"], path: "Packages/CassiniAudio/Tests/CassiniAudioTests"),
        .target(name: "COpusBridge", dependencies: [.product(name: "Copus", package: "swift-opus")]),
        .target(name: "CassiniAudio", dependencies: ["CassiniCore", "COpusBridge"], path: "Packages/CassiniAudio/Sources/CassiniAudio"),
        .testTarget(name: "CassiniInferenceTests", dependencies: ["CassiniInference"], path: "Packages/CassiniInference/Tests/CassiniInferenceTests"),
        .target(name: "CassiniInference", dependencies: ["CassiniNotebook", .product(name: "FluidAudio", package: "FluidAudio")], path: "Packages/CassiniInference/Sources/CassiniInference"),
        .target(name: "CZlib", path: "Sources/CZlib", publicHeadersPath: ".", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CassiniCore", dependencies: ["CZlib"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "CassiniCoreTests", dependencies: ["CassiniCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
        .target(name: "CassiniNotebook", dependencies: ["CassiniCore"], path: "Packages/CassiniNotebook/Sources/CassiniNotebook"),
        .testTarget(name: "CassiniNotebookTests", dependencies: ["CassiniNotebook", "CassiniCore"], path: "Packages/CassiniNotebook/Tests/CassiniNotebookTests")
    ]
)
