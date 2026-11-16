import Foundation
import Testing
import CassiniEngine
import CassiniNotebook

@Suite struct VoiceEnrollmentTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    func print(seconds: Double = 8) -> SpeakerPrint {
        SpeakerPrint(speakerID: "guided", model: VoiceprintModel.sha256,
                     vector: [1] + Array(repeating: 0, count: VoiceprintModel.dimension - 1), speechSeconds: seconds)
    }

    @Test func enrollmentRequiresUsableFourSecondPrint() throws {
        #expect(throws: VoiceEnrollment.Invalid.tooShort) { try VoiceEnrollment.validate(print(seconds: 3.999)) }
        #expect(throws: VoiceEnrollment.Invalid.tooShort) { try VoiceEnrollment.validate(print(seconds: .nan)) }
        var invalid = print(); invalid.vector = [0, 0]
        #expect(throws: VoiceEnrollment.Invalid.ambiguous) { try VoiceEnrollment.validate(invalid) }
        invalid = print(); invalid.model = "old"
        #expect(throws: VoiceEnrollment.Invalid.ambiguous) { try VoiceEnrollment.validate(invalid) }
        try VoiceEnrollment.validate(print(seconds: 4))
    }

    @Test func guidedSampleIsPrivateDurablePlayableAndSurvivesOrphanSweep() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceStore(root: root)
        let audio = root.appendingPathComponent("temporary.caf")
        try Data([1, 2, 3]).write(to: audio)
        try await store.enroll(name: "  Ada  ", print: print(), audio: audio)
        let voice = try #require(await store.voices().first)
        #expect(voice.name == "Ada")
        #expect(voice.samples.first?.guidedEnrollment == true)
        #expect(voice.recordingCount == 0)
        let sample = root.appendingPathComponent("PrivateVoices/Enrollment/\(voice.id.uuidString).caf")
        #expect(try Data(contentsOf: sample) == Data(contentsOf: audio))
        try await store.sweepOrphans(keeping: [])
        let reopened = try VoiceStore(root: root)
        #expect(await reopened.voices() == [voice])
        #expect(FileManager.default.fileExists(atPath: sample.path))
        #expect(await reopened.forget(voice.id) == .done)
        #expect(!FileManager.default.fileExists(atPath: sample.path))
    }

    @Test func forgetEveryoneDeletesGuidedAudioAndFailedEnrollmentKeepsNoFiles() async throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try VoiceStore(root: root)
        let audio = root.appendingPathComponent("sample.caf")
        try Data([4]).write(to: audio)
        await #expect(throws: VoiceEnrollment.Invalid.invalidName) { try await store.enroll(name: " ", print: print(), audio: audio) }
        #expect(await store.voices().isEmpty)
        try await store.enroll(name: "Grace", print: print(), audio: audio)
        #expect(await store.forgetEveryone() == .done)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("PrivateVoices/Enrollment").path))
    }
}
