// swift-tools-version: 6.2
import PackageDescription

// The sherpa-onnx runtime (Parakeet Ultra and the speaker models), iOS only: the codemyriad fork at 0c2ee3f and ONNX
// Runtime 1.27.1 as static xcframeworks from the fork's release v1.13.7-cassini-mobile.1 (the ONNX Runtime zip is a
// mirror of csukuangfj's, the same bytes). The lock is scripts/native-dependencies.json, and
// scripts/verify-native-runtime.sh compares each released target with it, so each stays on one line.
// CASSINI_SHERPA_LOCAL=1 links the xcframeworks that scripts/build-sherpa-xcframework.sh writes to the gitignored
// .tools/sherpa instead. Both binaries are iOS-only dependencies: `swift test` on macOS links no native code, though
// SwiftPM downloads the two release zips once to resolve the package (about 41 MB, then cached).
let sherpaLocal = !["", "0"].contains(Context.environment["CASSINI_SHERPA_LOCAL"] ?? "")
let iOSOnly = TargetDependencyCondition.when(platforms: [.iOS])
let sherpaBinaries: [Target] = sherpaLocal ? [
    .binaryTarget(name: "SherpaOnnxC", path: ".tools/sherpa/SherpaOnnxC.xcframework"),
    .binaryTarget(name: "onnxruntime", path: ".tools/sherpa/onnxruntime.xcframework")
] : [
    .binaryTarget(name: "SherpaOnnxC", url: "https://github.com/codemyriad/sherpa-onnx/releases/download/v1.13.7-cassini-mobile.1/sherpa-onnx-1.13.7-0c2ee3f-ios-no-tts.xcframework.zip", checksum: "6d305165927b0b2c1fa805b137fc2e345e1c128e92f800de80e90f7096a88fce"),
    .binaryTarget(name: "onnxruntime", url: "https://github.com/codemyriad/sherpa-onnx/releases/download/v1.13.7-cassini-mobile.1/onnxruntime-ios-static-xcframework-1.27.1.xcframework.zip", checksum: "985deaff345c7bcfbe4979b2daeec09d7a745b1e9cb73f37f4077364eb578e62")
]
let sherpaTarget: Target = .target(
    name: "CassiniSherpa",
    dependencies: ["CassiniEngine", "CassiniNotebook",
                   .target(name: "SherpaOnnxC", condition: iOSOnly), .target(name: "onnxruntime", condition: iOSOnly)],
    path: "Packages/CassiniSherpa/Sources/CassiniSherpa",
    linkerSettings: [.linkedLibrary("c++", .when(platforms: [.iOS])),
                     .linkedFramework("CoreML", .when(platforms: [.iOS])),
                     .linkedFramework("Accelerate", .when(platforms: [.iOS]))])

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
        .library(name: "CassiniAudio", targets: ["CassiniAudio"]),
        // The only importer of SherpaOnnxC, which iOS builds link (see above); on macOS it has no native code.
        .library(name: "CassiniSherpa", targets: ["CassiniSherpa"])
    ],
    // Zstandard decompresses the seekable .zst of every model file from the model host (`ZstdDecompressor`); Android
    // links zstd-jni with the same release.
    dependencies: [.package(url: "https://github.com/facebook/zstd.git", revision: "f8745da6ff1ad1e7bab384bd1f9d742439278e99"),
        .package(url: "https://github.com/alta/swift-opus.git", revision: "6f3cb6bd3ffed1fe5f06d00a962d5c191a50daf8")],
    targets: [
        .testTarget(name: "CassiniAudioTests", dependencies: ["CassiniAudio", "CassiniCore"], path: "Packages/CassiniAudio/Tests/CassiniAudioTests"),
        .target(name: "COpusBridge", dependencies: [.product(name: "Copus", package: "swift-opus")]),
        .target(name: "CassiniAudio", dependencies: ["CassiniCore", "COpusBridge"], path: "Packages/CassiniAudio/Sources/CassiniAudio"),
        .testTarget(name: "CassiniInferenceTests", dependencies: ["CassiniInference", "CassiniEngine", "CassiniEngineTesting", "CassiniNotebook", "CassiniCore", .product(name: "libzstd", package: "zstd")], path: "Packages/CassiniInference/Tests/CassiniInferenceTests"),
        .target(name: "CassiniInference", dependencies: ["CassiniCore", "CassiniEngine", "CassiniNotebook", .product(name: "libzstd", package: "zstd")], path: "Packages/CassiniInference/Sources/CassiniInference"),
        .target(name: "CZlib", path: "Sources/CZlib", publicHeadersPath: ".", linkerSettings: [.linkedLibrary("z")]),
        .target(name: "CassiniCore", dependencies: ["CZlib"]),
        .testTarget(name: "CassiniCoreTests", dependencies: ["CassiniCore"]),
        .target(name: "CassiniNotebook", dependencies: ["CassiniCore"], path: "Packages/CassiniNotebook/Sources/CassiniNotebook"),
        .testTarget(name: "CassiniNotebookTests", dependencies: ["CassiniNotebook", "CassiniCore"], path: "Packages/CassiniNotebook/Tests/CassiniNotebookTests",
                    resources: [.copy("Resources/export")]),
        .target(name: "CassiniEngine", dependencies: ["CassiniCore", "CassiniNotebook"], path: "Packages/CassiniEngine/Sources/CassiniEngine"),
        .target(name: "CassiniEngineTesting", dependencies: ["CassiniCore", "CassiniEngine", "CassiniNotebook"], path: "Packages/CassiniEngine/Sources/CassiniEngineTesting"),
        .testTarget(name: "CassiniEngineTests", dependencies: ["CassiniCore", "CassiniEngine", "CassiniEngineTesting", "CassiniNotebook"], path: "Packages/CassiniEngine/Tests/CassiniEngineTests",
                    resources: [.copy("Resources/language-tag"), .copy("Resources/model-host")]),
        sherpaTarget,
        .testTarget(name: "CassiniSherpaTests", dependencies: ["CassiniSherpa", "CassiniEngine", "CassiniNotebook"], path: "Packages/CassiniSherpa/Tests/CassiniSherpaTests")
    ] + sherpaBinaries
)
