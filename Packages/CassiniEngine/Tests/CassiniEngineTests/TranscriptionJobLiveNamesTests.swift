import CassiniCore
import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The draft names of a streaming run (Android's `names.json` and `TranscriptionJob.matchLive`): the two-speaker
/// script of `TranscriptionJobStreamingTests` (A until 35 s, B after it), whose CAM++ prints are axis 0 for A and axis
/// 1 for B, matched live after each window with the saved voices the host gives.
@Suite struct TranscriptionJobLiveNamesTests {
    typealias Harness = TranscriptionJobTests.Harness

    /// A's print is axis 0, B's axis 1.
    static let prints: @Sendable (String) -> [Float] = { speaker in
        var vector = [Float](repeating: 0, count: VoiceprintModel.dimension)
        vector[speaker.hasSuffix("1") ? 0 : 1] = 1
        return vector
    }

    /// A unit vector at cosine `score` from `axis`.
    static func near(_ axis: Int, _ score: Float = 1) -> [Float] {
        var vector = [Float](repeating: 0, count: VoiceprintModel.dimension)
        vector[axis] = score
        vector[2] = (1 - score * score).squareRoot()
        return vector
    }

    static func voice(_ name: String, _ vector: [Float]) -> SavedVoice {
        SavedVoice(id: UUID(), name: name, samples: [VoiceSample(noteID: UUID(), print: SpeakerPrint(
            speakerID: "src", model: VoiceprintModel.sha256, vector: vector, speechSeconds: 30))])
    }

    private func harness(autoName: Bool = true, voices: [SavedVoice]) async throws -> (Harness, WindowedTranscriber) {
        let transcriber = WindowedTranscriber()
        let engines = FakeSpeakerEngines(vector: Self.prints, turns: TranscriptionJobStreamingTests.twoSpeakers)
        let h = try await Harness(analyzer: FakeAnalyzer(engines: engines),
                                  settings: JobSettings(allowSpeechDownload: true, identifySpeakers: true,
                                                        allowSpeakerDownload: true, voicesGeneration: 7,
                                                        automaticallyNameVoices: autoName),
                                  engine: transcriber)
        h.host.voices = voices
        return (h, transcriber)
    }

    /// The draft's speaker ids, A's then B's, as the job's first window shows them.
    private final class Speakers: Sendable {
        private let prefix = Mutex<String?>(nil)
        func observe(_ event: JobEvent) {
            guard case .windowDone(_, _, let words) = event, let first = words.first?.speaker else { return }
            prefix.withLock { $0 = $0 ?? String(first.dropLast()) }
        }
        var a: String { (prefix.withLock { $0 } ?? "") + "1" }
        var b: String { (prefix.withLock { $0 } ?? "") + "2" }
    }

    // ports: TranscriptionJobTest#aRejectedVoiceIsNeverSuggestedAgain
    @Test func aRejectedVoiceIsNeverSuggestedAgain() async throws {
        let luca = Self.voice("Luca", Self.near(0, 0.6))
        let (h, transcriber) = try await harness(voices: [luca])
        let speakers = Speakers()
        let seen = Mutex<[DraftNames]>([])
        transcriber.beforeWindow = { [drafts = h.drafts, noteID = h.noteID] index in
            if index == 1 {
                // "Is this Luca?" after the first window; the user answers "Not Luca".
                #expect(drafts.current(noteID).live[speakers.a] == LiveMatch(luca.id, 0.6, .suggested))
                #expect(drafts.mutateIfOpen(noteID) { $0.reject(speakers.a, voice: luca.id, voiceName: "Luca") })
            } else if index > 1 {
                seen.withLock { $0.append(drafts.current(noteID)) }
            }
        }
        #expect(await h.run(observe: speakers.observe).outcome == .done)
        #expect(!seen.withLock { $0 }.isEmpty)
        #expect(seen.withLock { $0 }.allSatisfy { $0.live[speakers.a]?.voice != luca.id })
        // Nor in the final matching: the note gets the rejection with the speakers.
        let names = try #require(h.host.analyses.single?.names)
        #expect(names.live[speakers.a] == nil)
        #expect(names.excluded([speakers.a]) == [speakers.a: [luca.id]])
        #expect(names.labels.isEmpty)
    }

    // ports: TranscriptionJobTest#labelsFollowDraftNameThenAutoMatchThenPlaceholder (two speakers: the user's name,
    // then an automatic live match's)
    @Test func labelsFollowDraftNameThenAutoMatchThenPlaceholder() async throws {
        let marco = Self.voice("Marco", Self.near(1)), luca = Self.voice("Luca", Self.near(0))
        let (h, transcriber) = try await harness(voices: [marco, luca])
        let speakers = Speakers()
        let draft = Mutex<DraftState?>(nil)
        transcriber.beforeWindow = { [drafts = h.drafts, noteID = h.noteID] index in
            if index == 1 { drafts.mutateIfOpen(noteID) { $0.rename(speakers.a, "Chiara") } }
        }
        let (outcome, events) = await h.run(observe: { event in
            speakers.observe(event)
            if case .windowDone(_, _, let words) = event {
                draft.withLock { $0 = DraftState(words: words, tentativeFromMs: .max, namingOpen: true) }
            }
        })
        #expect(outcome == .done)
        let names = try #require(h.host.analyses.single?.names)
        #expect(names.labels == [speakers.a: "Chiara"])
        #expect(names.automatic == [speakers.b: "Marco"])
        // The draft as the screen shows it, and the closing of naming before the note is saved.
        let shown = DraftView.build(try #require(draft.withLock { $0 }), names: names,
                                    voiceNames: [marco.id: "Marco", luca.id: "Luca"])
        #expect(shown.labels == [speakers.a: "Chiara", speakers.b: "Marco"])
        #expect(shown.automatic == [speakers.b])
        #expect(events.contains(.namingClosed(matching: true)))
        #expect(!h.drafts.isOpen(h.noteID))
        #expect(!h.files.exists(h.noteID), "names.json goes with the work")
    }

    @Test func withoutNameStrongMatchesAutomaticallyALiveMatchIsOnlySuggested() async throws {
        let luca = Self.voice("Luca", Self.near(0))
        let (h, _) = try await harness(autoName: false, voices: [luca])
        #expect(await h.run().outcome == .done)
        let names = try #require(h.host.analyses.single?.names)
        #expect(names.live.values.map(\.state) == [.suggested])
        #expect(names.automatic.isEmpty)
    }

    @Test func yesLucaDuringTheRunIsRememberedWithTheSpeakers() async throws {
        let luca = Self.voice("Luca", Self.near(0, 0.6))
        let (h, transcriber) = try await harness(voices: [luca])
        let speakers = Speakers()
        transcriber.beforeWindow = { [drafts = h.drafts, noteID = h.noteID] index in
            if index == 1 {
                drafts.mutateIfOpen(noteID) { $0.confirm(speakers.a, voice: luca.id, name: "Luca", generation: 7, score: 0.6) }
            }
        }
        #expect(await h.run(observe: speakers.observe).outcome == .done)
        let names = try #require(h.host.analyses.single?.names)
        #expect(names.labels == [speakers.a: "Luca"])
        #expect(names.remembered == [speakers.a: .saved(luca.id)])
        #expect(names.live[speakers.a] == LiveMatch(luca.id, 0.6, .confirmed))
        #expect(names.generation == 7)
    }

    // ports: TranscriptionJobTest#forgetEveryoneDuringTheRunDropsTheSavedVoices
    @Test func forgetEveryoneDuringTheRunDropsTheSavedVoices() async throws {
        let luca = Self.voice("Luca", Self.near(0))
        let (h, transcriber) = try await harness(voices: [luca])
        transcriber.beforeWindow = { [host = h.host, drafts = h.drafts] index in
            if index == 1 {
                // As VoicesStore's Forget everyone: the generation moves on and every draft loses its matches.
                host.generation = 8
                drafts.mutateAll { $0.forgettingEveryone(generation: 8) }
            }
        }
        #expect(await h.run().outcome == .done)
        let names = try #require(h.host.analyses.single?.names)
        #expect(names.live.isEmpty && names.automatic.isEmpty)
        // The note's matching then drops the prints: they carry the run's generation.
        #expect(h.applied.single?.generation == 7)
    }

    @Test func aPausedRunKeepsItsNamesOpenAndAResumedOneGoesOnWithThem() async throws {
        let (h, transcriber) = try await harness(voices: [])
        let speakers = Speakers()
        let stop = StopSignal()
        let pause = WindowedTranscriber.pause(stop, afterWindows: 1)
        transcriber.afterWindow = { [drafts = h.drafts, noteID = h.noteID] windows in
            if windows == 1 { drafts.mutateIfOpen(noteID) { $0.rename(speakers.a, "Chiara") } }
            try await pause(windows)
        }
        #expect(await h.run(stop: stop, observe: speakers.observe).outcome == .paused(.user))
        #expect(h.drafts.isOpen(h.noteID))
        #expect(h.drafts.current(h.noteID).labels == [speakers.a: "Chiara"])
        // A new process reads names.json beside the checkpoint.
        let reread = DraftNamesStore(notes: h.notes)
        #expect(reread.current(h.noteID).labels == [speakers.a: "Chiara"])

        transcriber.afterWindow = { _ in }
        #expect(await h.run().outcome == .done)
        #expect(h.host.analyses.single?.names?.labels == [speakers.a: "Chiara"])
    }
}

private extension Array {
    var single: Element? { count == 1 ? first : nil }
}
