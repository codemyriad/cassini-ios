import Foundation
import Testing
@testable import CassiniEngine
import CassiniNotebook

/// Android's ModelPlanTest. The figures are Android's: the speaker parts are Nemotron Sortformer and CAM++, which the
/// catalog lists for the speaker package; until it lands, the Model download screen still shows FluidAudio's speaker
/// figures (`ModelDownloadPlan`).
@Suite struct ModelPlanTests {
    private let mib = 1024.0 * 1024.0

    // ports: ModelPlanTest#aFreshInstallNeedsAbout861MiBAndShows730
    @Test func aFreshInstallNeedsAbout861MiBAndShows730() {
        let plan = ModelPlan.of { _ in false }
        #expect(plan.parts == [.speech, .speakers, .voices])
        #expect(plan.missing.map(\.mebibytes) == [640, 62, 28])
        #expect(plan.totalMebibytes == 730)
        #expect(ModelCatalog.mebibytes(plan.totalBytes) == 730)
        let speech = ModelCatalog.parakeet.artifactBytes + ModelCatalog.sileroVad.size
        let speakers = ModelCatalog.diarizationDownload.size + ModelCatalog.diarizationModel.size
        let voices = ModelCatalog.voiceprintModel.size
        #expect(plan.requiredFreeBytes == speech + speakers + voices + ArtifactFetcher.slackBytes)
        #expect((Double(plan.requiredFreeBytes) / mib).rounded() == 861)
        #expect(plan.requiredFreeMebibytes == 860)
    }

    // ports: ModelPlanTest#theDownloadBytesOfEachPartAreWhatTheNetworkCarries
    @Test func theDownloadBytesOfEachPartAreWhatTheNetworkCarries() {
        let plan = ModelPlan.of { _ in false }
        #expect(plan.downloadBytes == [
            .speech: ModelCatalog.parakeetBytes + ModelCatalog.sileroVad.size,
            .speakers: ModelCatalog.diarizationDownload.size,
            .voices: ModelCatalog.voiceprintModel.size,
        ])
        #expect(plan.downloadBytes.values.reduce(0, +) == plan.totalBytes)
    }

    // ports: ModelPlanTest#aReadySpeechPartLeavesOnlyTheSpeakerParts
    @Test func aReadySpeechPartLeavesOnlyTheSpeakerParts() {
        let plan = ModelPlan.of { $0 == ModelCatalog.parakeet }
        #expect(plan.parts == [.speakers, .voices])
        #expect(plan.totalMebibytes == 90)
        let expected = ModelCatalog.diarizationDownload.size + ModelCatalog.diarizationModel.size
            + ModelCatalog.voiceprintModel.size + ArtifactFetcher.slackBytes
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
        #expect(plan.missing.first?.mebibytes == 640)
    }

    // ports: ModelPlanTest#onlyTheVoiceModelMissing
    @Test func onlyTheVoiceModelMissing() {
        let plan = ModelPlan.of { $0 != ModelCatalog.voiceprint }
        #expect(plan.parts == [.voices])
        #expect(plan.totalMebibytes == 28)
        #expect(plan.requiredFreeBytes == ModelCatalog.voiceprintModel.size + ArtifactFetcher.slackBytes)
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
                let perFile = model.download.map { [$0.size + model.artifactBytes] } ?? model.artifacts.map(\.size)
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
