import Foundation
import Testing
@testable import CassiniEngine
import CassiniNotebook

/// The pins, URLs, directories and markers of the installed models. Installed phones depend on every one of them.
@Suite struct ModelCatalogTests {
    // ports: ModelCatalogTest#parakeetIsTheHuggingFaceRevisionMarkedByThatRevision
    @Test func parakeetIsTheHuggingFaceRevisionMarkedByThatRevision() {
        let parakeet = ModelCatalog.parakeet
        #expect(parakeet.directory == "parakeet-ultra")
        #expect(parakeet.markerFile == "verified")
        #expect(parakeet.markerValue == "b86784a3a5356cbd126f710b61cd90c5fe5898f1")
        #expect(parakeet.artifacts.map(\.name) == ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"])
        #expect(parakeet.artifacts.map(\.size) == [652_282_347, 11_845_275, 6_355_277, 93_939])
        #expect(parakeet.artifacts.map(\.sha256) == [
            "f4d06712d32431b1718eceba2153c314ac4425e8fe708a3534f5e56c5ad53697",
            "94373c6405c8149d1c9d1e9862514e0e3e88dab1c7de18fac9d5df9c6ba5efdd",
            "8a71aaccfdba3d451775507a889afd2257d2e754463fd81095a8c8f290f924c2",
            "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d",
        ])
        for artifact in parakeet.artifacts {
            #expect(artifact.url == "https://huggingface.co/tpmaerk/parakeet-ultra-sherpa-onnx-int8/resolve/"
                    + "b86784a3a5356cbd126f710b61cd90c5fe5898f1/\(artifact.name)")
        }
        #expect(ModelCatalog.parakeetModelID == "moondream/parakeet-ultra")
        #expect(ModelCatalog.parakeetDisplayName == "Parakeet Ultra")
        #expect(ModelCatalog.parakeetPrecision == "INT8")
    }

    // ports: ModelCatalogTest#everySpeechModelOfADocumentHasAName
    @Test func everySpeechModelOfADocumentHasAName() {
        #expect(ModelCatalog.speechModelNames[ModelCatalog.parakeetModelID] == "Parakeet Ultra")
        #expect(ModelCatalog.speechModelNames["nvidia/parakeet-tdt-0.6b-v3"] == "Parakeet TDT 0.6B v3")
        #expect(ModelCatalog.parakeetV3Revision == "2bda32ec70b097a55adaa07d9a7173915b43cc78")
    }

    // ports: ModelCatalogTest#theDetectorAndSpeakerModelsAreMarkedByTheirHashes
    @Test func theDetectorAndSpeakerModelsAreMarkedByTheirHashes() {
        #expect(ModelCatalog.vad.directory == "vad")
        #expect(ModelCatalog.vad.markerFile == "verified")
        #expect(ModelCatalog.vad.markerValue == ModelCatalog.sileroVad.sha256)
        #expect(ModelCatalog.sileroVad == Artifact("silero_vad.onnx", 643_854,
                                                   "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6",
                                                   "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/silero_vad.onnx"))
        #expect(ModelCatalog.diarization.directory == "speaker-models")
        #expect(ModelCatalog.diarization.markerFile == "verified")
        #expect(ModelCatalog.diarization.markerValue == "01d1f893f394cc0418ae78425d216ed62c334c0125e650135332a7a8e595f168")
        #expect(ModelCatalog.diarization.download == ModelCatalog.diarizationDownload)
        #expect(ModelCatalog.diarizationDownload.url.hasPrefix("https://dist.gocassini.com/models/files/"))
        #expect(ModelCatalog.voiceprint.directory == "speaker-models")
        #expect(ModelCatalog.voiceprint.markerFile == "verified-voiceprint")
        #expect(ModelCatalog.voiceprint.markerValue == "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b")
        #expect(ModelCatalog.voiceprintModel.name == "voiceprint-campplus.onnx")
    }

    // ports: ModelCatalogTest#onlyTheThreeModelHostsAreContacted
    @Test func onlyTheThreeModelHostsAreContacted() {
        let hosts = (ModelCatalog.consented + [ModelCatalog.vad]).flatMap { $0.artifacts + [$0.download].compactMap { $0 } }
            .filter { !$0.url.isEmpty }.compactMap { URL(string: $0.url)?.host() }
        #expect(Set(hosts) == ["huggingface.co", "github.com", "dist.gocassini.com"])
    }

    // ports: ModelCatalogTest#aModelIsReadyOnlyWithEveryFullFileAndItsMarker
    @Test func aModelIsReadyOnlyWithEveryFullFileAndItsMarker() throws {
        for model in [ModelCatalog.parakeet, ModelCatalog.vad, ModelCatalog.diarization, ModelCatalog.voiceprint] {
            let folder = TemporaryFolder()
            defer { folder.remove() }
            #expect(!model.ready(in: folder.root))
            install(model, in: folder.root, marker: "stale")
            #expect(!model.ready(in: folder.root))
            install(model, in: folder.root)
            #expect(model.ready(in: folder.root))
            try Data(count: 10).write(to: model.directory(in: folder.root).appendingPathComponent(model.artifacts[0].name))
            #expect(!model.ready(in: folder.root))
        }
    }

    // ports: ModelCatalogTest#theDiarizerAndVoiceprintShareADirectoryWithoutSharingAMarker
    @Test func theDiarizerAndVoiceprintShareADirectoryWithoutSharingAMarker() {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        install(ModelCatalog.voiceprint, in: folder.root)
        #expect(ModelCatalog.voiceprint.ready(in: folder.root))
        #expect(!ModelCatalog.diarization.ready(in: folder.root))
    }

    // ports: ModelCatalogTest#theConsentDialogQuotesTheBytesFetched
    @Test func theConsentDialogQuotesTheBytesFetched() {
        #expect(ModelCatalog.parakeetBytes == ModelCatalog.parakeetArtifacts.reduce(0) { $0 + $1.size })
        #expect(ModelCatalog.speakerBytes == ModelCatalog.diarizationDownload.size)
        #expect(ModelCatalog.voiceprintBytes == ModelCatalog.voiceprintModel.size)
        #expect(ModelCatalog.mebibytes(ModelCatalog.voiceprintBytes) == 28)
        #expect(ModelCatalog.mebibytes(1) == 1)
        #expect(ModelCatalog.mebibytes(ModelCatalog.parakeetBytes) == 640, "the speech row and the consent screen")
    }

    /// `scripts/ci-models.json`; `CASSINI_CI_MODELS` names another copy (Android's `cassini.ciModels`).
    private static var ciModels: URL {
        if let path = ProcessInfo.processInfo.environment["CASSINI_CI_MODELS"], !path.isEmpty {
            return URL(fileURLWithPath: path)
        }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<6 { root.deleteLastPathComponent() }
        return root.appendingPathComponent("scripts/ci-models.json")
    }

    private struct List: Decodable {
        struct Model: Decodable {
            var directory: String
            var marker: String
            var markerValue: String
            var artifacts: [File]
            var download: File?
        }

        struct File: Decodable {
            var name: String
            var size: Int64
            var sha256: String
            var url: String
        }

        var models: [Model]
    }

    // ports: ModelCatalogTest#theCiModelListIsTheCatalog
    /// scripts/ci-models.json gives scripts/fetch-ci-models.py the same files, URLs and markers as the catalog.
    @Test func theCiModelListIsTheCatalog() throws {
        let listed = try JSONDecoder().decode(List.self, from: Data(contentsOf: Self.ciModels)).models
        // Every model that the app installs: the consented download and the speech detector.
        let catalog = byDirectory(ModelCatalog.consented + [ModelCatalog.vad])
        func artifact(_ file: List.File) -> Artifact { Artifact(file.name, file.size, file.sha256, file.url) }
        let models = listed.map {
            ModelDescriptor($0.directory, $0.artifacts.map(artifact), $0.marker, $0.markerValue,
                            download: $0.download.map(artifact))
        }
        #expect(byDirectory(models) == catalog)
    }

    /// A stable sort by directory, as Kotlin's `sortedBy`.
    private func byDirectory(_ models: [ModelDescriptor]) -> [ModelDescriptor] {
        models.enumerated().sorted { ($0.element.directory, $0.offset) < ($1.element.directory, $1.offset) }.map(\.element)
    }
}
