// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Cassini",
    platforms: [.iOS("26.0"), .macOS("26.0")],
    products: [
        .library(name: "CassiniCore", targets: ["CassiniCore"]),
        .library(name: "CassiniNotebook", targets: ["CassiniNotebook"]),
        .library(name: "CassiniEngine", targets: ["CassiniEngine"]),
        // Fakes for tests and UI-test launches. Every source is under `#if DEBUG`, so a Release build links an empty module.
        .library(name: "CassiniEngineTesting", targets: ["CassiniEngineTesting"]),
        .library(name: "CassiniInference", targets: ["CassiniInference"]),
        .library(name: "CassiniAudio", targets: ["CassiniAudio"])
    ],
    dependencies: [.package(url: "https://github.com/FluidInference/FluidAudio.git", revision: "e560c6445ffdc42e60c7b282d162aae271f18e2a", traits: []),
        .package(url: "https://github.com/alta/swift-opus.git", revision: "6f3cb6bd3ffed1fe5f06d00a962d5c191a50daf8")],
    targets: [
        .testTarget(name: "CassiniAudioTests", dependencies: ["CassiniAudio", "CassiniCore"], path: "Packages/CassiniAudio/Tests/CassiniAudioTests"),
        .target(name: "COpusBridge", dependencies: [.product(name: "Copus", package: "swift-opus")]),
        .target(name: "CassiniAudio", dependencies: ["CassiniCore", "COpusBridge"], path: "Packages/CassiniAudio/Sources/CassiniAudio"),
        .testTarget(name: "CassiniInferenceTests", dependencies: ["CassiniInference", "CassiniEngine", "CassiniEngineTesting", "CassiniNotebook"], path: "Packages/CassiniInference/Tests/CassiniInferenceTests"),
        .target(name: "CassiniInference", dependencies: ["CassiniEngine", "CassiniNotebook", .product(name: "FluidAudio", package: "FluidAudio")], path: "Packages/CassiniInference/Sources/CassiniInference"),
        .target(name: "CZlib", path: "Sources/CZlib", publicHeadersPath: ".", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CassiniCore", dependencies: ["CZlib"]),
        .testTarget(name: "CassiniCoreTests", dependencies: ["CassiniCore"]),
        .target(name: "CassiniNotebook", dependencies: ["CassiniCore"], path: "Packages/CassiniNotebook/Sources/CassiniNotebook"),
        .testTarget(name: "CassiniNotebookTests", dependencies: ["CassiniNotebook", "CassiniCore"], path: "Packages/CassiniNotebook/Tests/CassiniNotebookTests",
                    resources: [.copy("Resources/export")]),
        .target(name: "CassiniEngine", dependencies: ["CassiniCore", "CassiniNotebook"], path: "Packages/CassiniEngine/Sources/CassiniEngine"),
        .target(name: "CassiniEngineTesting", dependencies: ["CassiniCore", "CassiniEngine", "CassiniNotebook"], path: "Packages/CassiniEngine/Sources/CassiniEngineTesting"),
        .testTarget(name: "CassiniEngineTests", dependencies: ["CassiniEngine", "CassiniEngineTesting", "CassiniNotebook"], path: "Packages/CassiniEngine/Tests/CassiniEngineTests")
    ]
)
