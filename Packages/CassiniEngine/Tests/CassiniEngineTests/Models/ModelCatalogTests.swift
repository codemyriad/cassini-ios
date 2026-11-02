import Foundation
import Testing
@testable import CassiniEngine
import CassiniNotebook

/// The pins, URLs and directories of the installed models. Installed phones depend on every one of them.
@Suite struct ModelCatalogTests {
    // ports: ModelCatalogTest#parakeetIsTheModelHostsUltraInt8MarkedByItsSourceHash (iOS has no marker: the revision
    // directory is the pin)
    @Test func parakeetIsTheModelHostsUltraInt8MarkedByItsSourceHash() {
        let parakeet = ModelCatalog.parakeet
        #expect(parakeet.id == "parakeet-ultra-0.6b-int8")
        #expect(parakeet.sourceSha256 == "18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9")
        #expect(parakeet.directory
                == "models/parakeet-ultra-0.6b-int8/18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9")
        #expect(parakeet.pin == "parakeet-ultra-0.6b-int8@18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9")
        #expect(ModelCatalog.parakeetRevision == parakeet.sourceSha256)
        #expect(parakeet.artifacts.map(\.name) == ["encoder.int8.onnx", "decoder.int8.onnx", "joiner.int8.onnx", "tokens.txt"])
        #expect(parakeet.artifacts.map(\.size) == [652_282_922, 11_845_274, 6_355_277, 93_939])
        #expect(parakeet.artifacts.map(\.sha256) == [
            "299617fefd4664d1c115b691dcb6413cabcdbcc694cdf3cb4464b72c5fc3ae69",
            "1fab98fe6c12aded87d2da66272cc9e148d0a0044ce3850a12fe56302ec4a922",
            "8a71aaccfdba3d451775507a889afd2257d2e754463fd81095a8c8f290f924c2",
            "d58544679ea4bc6ac563d1f545eb7d474bd6cfa467f0a6e2c1dc1c7d37e3c35d",
        ])
        #expect(parakeet.artifacts.map { $0.download?.size } == [452_306_705, 8_841_708, 3_714_640, 45_831])
        #expect(parakeet.artifacts.map { $0.download?.sha256 } == [
            "caf7a38f2ad3224c1863564fb6e975a11aa3ae6ad1e7ad0bee5c4f5e018babb4",
            "69e2e91d01225bc552f8b0113630562fc52622cb2a3c61ef4445ee779f06b295",
            "639fda62a71242a8d7cefb6647f2094eb8ac783925ce91cbd047a0de6988f396",
            "5b3811f0c23fefc86835981f0a23ecfb817999df272ad744c597e5b669ea1b4a",
        ])
        #expect(ModelCatalog.parakeetModelID == "moondream/parakeet-ultra")
        #expect(ModelCatalog.parakeetDisplayName == "Parakeet Ultra")
        #expect(ModelCatalog.parakeetPrecision == "INT8")
    }

    // ports: ModelCatalogTest#theSpeechModelOfThisBuildHasAName (iOS also names its pin, the model string it writes),
    // with NoteMappingTest#documentInfoNamesTheSpeechModel's precision rule
    @Test func theSpeechModelOfThisBuildHasAName() {
        #expect(ModelCatalog.speechModelNames == [
            ModelCatalog.parakeetProvenanceModel: "Parakeet Ultra, INT8",
            "moondream/parakeet-ultra INT8": "Parakeet Ultra, INT8",
            "moondream/parakeet-ultra": "Parakeet Ultra",
        ])
    }

    /// Document info names an iOS Parakeet run's model by its pin through the catalog's names.
    @Test func documentInfoNamesAParakeetRunParakeetUltraInt8() {
        let run = TranscriptProvenance.parakeetRun(model: ModelCatalog.parakeetProvenanceModel,
                                                   revision: ModelCatalog.parakeetRevision, segmentation: "speech",
                                                   inferenceMs: 1, resumedFromMs: 0,
                                                   device: RunDevice(model: "iPhone17,1", system: "iOS 26.0"))
        #expect(DocumentInfoFacts.modelName(run, speechModels: ModelCatalog.speechModelNames) == "Parakeet Ultra, INT8")
    }

    /// iOS writes D16 §5's model string; Android still writes `<id> <precision>`.
    @Test func aParakeetTranscriptNamesTheModelByItsPin() {
        #expect(ModelCatalog.parakeetProvenanceModel
                == "parakeet-ultra-0.6b-int8@18cb623004dd6c15999b93cb70b14d8a1f6e8f3a2a97ff733f104bfc3494f6a9")
    }

    // ports: ModelCatalogTest#theDetectorAndSpeakerModelsLiveInTheirOwnDirectories
    @Test func theDetectorAndSpeakerModelsLiveInTheirOwnDirectories() {
        #expect(ModelCatalog.vad.directory == "models/silero-vad/\(ModelCatalog.sileroVad.sha256)")
        #expect(ModelCatalog.vad.sourceSha256 == "9e2449e1087496d8d4caba907f23e0bd3f78d91fa552479bb9c23ac09cbb1fd6")
        #expect(ModelCatalog.sileroVad.name == "silero_vad.onnx")
        #expect(ModelCatalog.sileroVad.size == 643_854)
        let diarizer = "47c221ea9b4d4e7f6c108bd098e769bc706cdc986c29f6133c93cae335fe6779"
        #expect(ModelCatalog.diarization.directory == "models/nemotron-3-diarization-int8/\(diarizer)")
        #expect(ModelCatalog.diarizationModel.sha256 == diarizer)
        #expect(ModelCatalog.diarizationModel.name == "model.int8.onnx")
        #expect(ModelCatalog.diarizationModel.size == 103_967_426)
        #expect(ModelCatalog.diarizationSourceRevision == "f667ed73aee57d40cc39428eb768b4fd87a0a29e")
        // The saved-voice identity: the same CAM++ file as before, so saved voices stay valid.
        let voiceprint = "357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b"
        #expect(ModelCatalog.voiceprintModel.sha256 == voiceprint)
        #expect(VoiceprintModel.sha256 == voiceprint)
        #expect(ModelCatalog.voiceprintModel.size == 29_596_978)
        #expect(ModelCatalog.voiceprint.directory == "models/campplus-voxceleb-16k/\(voiceprint)")
        #expect(ModelCatalog.voiceprintModel.name == "3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx")
        let all = ModelCatalog.consented + [ModelCatalog.vad]
        #expect(Set(all.map(\.directory)).count == all.count)
        #expect(Set(ModelCatalog.all) == Set(all))
    }

    // ports: ModelCatalogTest#everyFileIsASeekableZstandardObjectOnTheModelHost
    @Test func everyFileIsASeekableZstandardObjectOnTheModelHost() throws {
        for file in ModelCatalog.all.flatMap(\.artifacts) {
            let download = try #require(file.download)
            #expect(download.name == "\(file.name).zst")
            #expect(download.url == "https://dist.gocassini.com/models/files/\(download.sha256)/\(file.name).zst")
            #expect(file.url.isEmpty)
            #expect(!file.name.contains("/") && file.name != ModelDescriptor.noticeFile, "a flat path that is not the notices")
        }
        #expect(ModelCatalog.downloadHosts == ["dist.gocassini.com"])
        #expect(ModelCatalog.manifestURL == "https://dist.gocassini.com/manifest.json")
        #expect(ModelCatalog.noticeURL == "https://dist.gocassini.com/NOTICE.txt")
    }

    // ports: ModelCatalogTest#aModelIsReadyOnlyWithEveryFullFileAndItsMarker (iOS: the notices stand where the marker
    // was, in a revision directory that only appears complete)
    @Test func aModelIsReadyOnlyWithEveryFullFileAndItsMarker() throws {
        for model in ModelCatalog.all {
            let folder = TemporaryFolder()
            defer { folder.remove() }
            #expect(!model.ready(in: folder.root))
            install(model, in: folder.root)
            #expect(model.ready(in: folder.root))
            let notice = model.directory(in: folder.root).appendingPathComponent(ModelDescriptor.noticeFile)
            try Data().write(to: notice)
            #expect(!model.ready(in: folder.root), "an empty notices file")
            try FileManager.default.removeItem(at: notice)
            #expect(!model.ready(in: folder.root), "no notices")
            install(model, in: folder.root)
            try Data(count: 10).write(to: model.directory(in: folder.root).appendingPathComponent(model.artifacts[0].name))
            #expect(!model.ready(in: folder.root))
            // The same files in the staging directory are not an install.
            let staging = model.staging(in: folder.root)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            sparse(model, in: staging)
            try FileManager.default.removeItem(at: model.directory(in: folder.root))
            #expect(model.complete(staging))
            #expect(!model.ready(in: folder.root))
        }
    }

    // ports: ModelCatalogTest#theDiarizerAndVoiceprintAreInstalledApart
    @Test func theDiarizerAndVoiceprintAreInstalledApart() {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        install(ModelCatalog.voiceprint, in: folder.root)
        #expect(ModelCatalog.voiceprint.ready(in: folder.root))
        #expect(!ModelCatalog.diarization.ready(in: folder.root))
    }

    // ports: ModelCatalogTest#theConsentDialogQuotesTheCompressedBytesFetched
    @Test func theConsentDialogQuotesTheCompressedBytesFetched() {
        #expect(ModelCatalog.parakeetBytes == ModelCatalog.parakeetArtifacts.reduce(0) { $0 + ($1.download?.size ?? 0) })
        #expect(ModelCatalog.speakerBytes == ModelCatalog.diarizationModel.download?.size)
        #expect(ModelCatalog.voiceprintBytes == ModelCatalog.voiceprintModel.download?.size)
        #expect(ModelCatalog.mebibytes(ModelCatalog.parakeetBytes) == 440, "the speech row and the consent screen")
        #expect(ModelCatalog.mebibytes(ModelCatalog.voiceprintBytes) == 26)
        #expect(ModelCatalog.mebibytes(1) == 1)
    }

    /// "Where the models come from" lists the manifest, the notices and the seven files, all on the model host.
    @Test func everyDownloadIsOnTheModelHost() {
        let downloads = ModelCatalog.downloads
        #expect(downloads.count == 9)
        #expect(downloads.prefix(2).map(\.url.absoluteString) == [ModelCatalog.manifestURL, ModelCatalog.noticeURL])
        #expect(downloads.allSatisfy { $0.url.scheme == "https" && $0.url.host() == "dist.gocassini.com" })
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
            var id: String
            var sourceSha256: String
            var directory: String
            var artifacts: [File]
        }

        final class File: Decodable {
            var name: String
            var size: Int64
            var sha256: String
            var url: String?
            var download: File?
        }

        var manifest: String
        var notice: String
        var models: [Model]
    }

    // ports: ModelCatalogTest#theCiModelListIsTheCatalog
    /// scripts/ci-models.json gives scripts/fetch-ci-models.py the same pins, files, URLs and directories as the
    /// catalog.
    @Test func theCiModelListIsTheCatalog() throws {
        let list = try JSONDecoder().decode(List.self, from: Data(contentsOf: Self.ciModels))
        #expect(list.manifest == ModelCatalog.manifestURL)
        #expect(list.notice == ModelCatalog.noticeURL)
        func artifact(_ file: List.File) -> Artifact {
            Artifact(file.name, file.size, file.sha256, file.url ?? "", download: file.download.map(artifact))
        }
        let models = list.models.map { listed in
            let model = ModelDescriptor(listed.id, listed.sourceSha256, listed.artifacts.map(artifact))
            #expect(model.directory == listed.directory)
            return model
        }
        // Every model that the app installs: the consented download and the speech detector.
        #expect(byDirectory(models) == byDirectory(ModelCatalog.consented + [ModelCatalog.vad]))
    }

    /// A stable sort by directory, as Kotlin's `sortedBy`.
    private func byDirectory(_ models: [ModelDescriptor]) -> [ModelDescriptor] {
        models.enumerated().sorted { ($0.element.directory, $0.offset) < ($1.element.directory, $1.offset) }.map(\.element)
    }
}
