import Foundation
import Testing
@testable import CassiniEngine
import CassiniNotebook

/// Android's ModelPlanTest, with the figures of the model host's files (D4): every file is a compressed download.
@Suite struct ModelPlanTests {
    private let mib = 1024.0 * 1024.0

    /// What stays on disk: the decompressed file.
    private func installed(_ artifact: Artifact) -> Int64 { artifact.size }

    /// What one file needs while it installs: its download and its decompressed copy.
    private func peak(_ artifact: Artifact) -> Int64 { (artifact.download?.size ?? 0) + artifact.size }

    // ports: ModelPlanTest#aFreshInstallNeedsAbout1231MiBAndShows528
    @Test func aFreshInstallNeedsAbout1231MiBAndShows528() {
        let plan = ModelPlan.of { _ in false }
        #expect(plan.parts == [.speech, .speakers, .voices])
        #expect(plan.missing.map(\.mebibytes) == [440, 62, 26])
        #expect(plan.totalMebibytes == 528)
        // The rounded parts add up on screen; the rounded sum of the bytes would say 530.
        #expect(ModelCatalog.mebibytes(plan.totalBytes) == 530)
        #expect(plan.totalBytes == 557_432_379)
        let speech = ModelCatalog.parakeetArtifacts.reduce(0) { $0 + installed($1) } + installed(ModelCatalog.sileroVad)
        let speakers = installed(ModelCatalog.diarizationModel)
        let voices = installed(ModelCatalog.voiceprintModel)
        // Every installed file, plus the one download being decompressed at a time: at most the speech encoder's.
        let encoder = ModelCatalog.parakeetArtifacts.first { $0.name == "encoder.int8.onnx" }?.download?.size ?? 0
        #expect(plan.requiredFreeBytes == speech + speakers + voices + encoder + ArtifactFetcher.slackBytes)
        #expect(plan.requiredFreeBytes == 1_290_646_807)
        #expect((Double(plan.requiredFreeBytes) / mib).rounded() == 1231)
        #expect(plan.requiredFreeMebibytes == 1230)
    }

    // ports: ModelPlanTest#theDownloadBytesOfEachPartAreWhatTheNetworkCarries
    @Test func theDownloadBytesOfEachPartAreWhatTheNetworkCarries() {
        let plan = ModelPlan.of { _ in false }
        #expect(plan.downloadBytes == [
            .speech: ModelCatalog.parakeetBytes + (ModelCatalog.sileroVad.download?.size ?? 0),
            .speakers: ModelCatalog.diarizationModel.download?.size ?? 0,
            .voices: ModelCatalog.voiceprintModel.download?.size ?? 0,
        ])
        #expect(plan.downloadBytes.values.reduce(0, +) == plan.totalBytes)
    }

    // ports: ModelPlanTest#aReadySpeechPartLeavesOnlyTheSpeakerParts
    @Test func aReadySpeechPartLeavesOnlyTheSpeakerParts() {
        let plan = ModelPlan.of { $0 == ModelCatalog.parakeet }
        #expect(plan.parts == [.speakers, .voices])
        #expect(plan.totalMebibytes == 88)
        let largest = ModelCatalog.diarizationModel.download?.size ?? 0
        let expected = installed(ModelCatalog.diarizationModel) + installed(ModelCatalog.voiceprintModel) + largest
            + ArtifactFetcher.slackBytes
        #expect(plan.requiredFreeBytes == expected)
    }

    // ports: ModelPlanTest#aMissingDetectorAloneDoesNotMakeSpeechMissing
    @Test func aMissingDetectorAloneDoesNotMakeSpeechMissing() {
        let plan = ModelPlan.of { $0 != ModelCatalog.vad }
        #expect(plan.isEmpty)
        #expect(plan.requiredFreeBytes == 0)
        #expect(plan.totalMebibytes == 0)
    }

    // ports: ModelPlanTest#aMissingPartBringsOnlyItsModelsThatAreNotReady
    @Test func aMissingPartBringsOnlyItsModelsThatAreNotReady() {
        let plan = ModelPlan.of { $0 == ModelCatalog.vad }
        #expect(plan.missing.first { $0.part == .speech }?.models == [ModelCatalog.parakeet])
        #expect(plan.missing.first?.mebibytes == 440)
    }

    // ports: ModelPlanTest#onlyTheVoiceModelMissing
    @Test func onlyTheVoiceModelMissing() {
        let plan = ModelPlan.of { $0 != ModelCatalog.voiceprint }
        #expect(plan.parts == [.voices])
        #expect(plan.totalMebibytes == 26)
        #expect(plan.requiredFreeBytes == peak(ModelCatalog.voiceprintModel) + ArtifactFetcher.slackBytes)
    }

    // ports: ModelPlanTest#thePlanForADirectoryReadsTheInstalledModels
    @Test func thePlanForADirectoryReadsTheInstalledModels() {
        let folder = TemporaryFolder()
        defer { folder.remove() }
        #expect(ModelPlan.of(root: folder.root).parts == ModelPart.allCases)
        install(ModelCatalog.parakeet, in: folder.root)
        install(ModelCatalog.diarization, in: folder.root)
        #expect(ModelPlan.of(root: folder.root).parts == [.voices])
        install(ModelCatalog.voiceprint, in: folder.root)
        #expect(ModelPlan.of(root: folder.root).isEmpty)
    }

    // ports: ModelPlanTest#thePlanCoversEverySpaceCheckOfTheInstallThatFollows
    /// A plan that passes its space check must not fail later with Not enough storage: for every set of ready models,
    /// the plan needs at least what ArtifactFetcher checks before each file, and at least one model's whole download
    /// plus the slack.
    @Test func thePlanCoversEverySpaceCheckOfTheInstallThatFollows() {
        let all = ModelPart.allCases.flatMap(\.models)
        for mask in 0..<(1 << all.count) {
            let ready = all.enumerated().filter { mask & (1 << $0.offset) != 0 }.map(\.element)
            let plan = ModelPlan.of { ready.contains($0) }
            for model in plan.missing.flatMap(\.models) {
                // ArtifactFetcher.fetchCompressed checks each file's download and its decompressed copy.
                let perFile = model.artifacts.map(peak)
                for need in perFile + [model.downloadBytes] {
                    #expect(plan.requiredFreeBytes >= need + ArtifactFetcher.slackBytes, "\(ready): \(need)")
                }
            }
        }
    }

    // ports: ModelPlanTest#eachPartIsLedByTheModelThatMakesItReady
    @Test func eachPartIsLedByTheModelThatMakesItReady() {
        #expect(ModelPart.speech.primary == ModelCatalog.parakeet)
        #expect(ModelPart.speech.models == [ModelCatalog.parakeet, ModelCatalog.vad])
        #expect(ModelPart.speakers.models == [ModelCatalog.diarization])
        #expect(ModelPart.voices.models == [ModelCatalog.voiceprint])
    }
}
