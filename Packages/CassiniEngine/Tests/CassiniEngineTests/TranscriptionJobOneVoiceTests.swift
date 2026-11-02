import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionJobTests {
    /// D59 (amended after Android R9): the words go into the note in one voice, an id new to the run (`<prefix>1`, as
    /// Android writes `diar_<run>_1`) labelled "Speaker 1" in the user's language; the speaker step replaces it, and
    /// without one the note keeps it.
    @Suite struct OneVoice {
        static let twoSpeakers = SpeakerAnalysis(turns: [.init(speakerID: "a", start: 0, end: 30),
                                                         .init(speakerID: "b", start: 30, end: 70)], prints: [])
        static let off = JobSettings(allowSpeechDownload: true, identifySpeakers: false, allowSpeakerDownload: true)

        /// Expects every passage of `note` in one voice of its run, the note's only speaker, labelled "Speaker 1";
        /// returns its id.
        @discardableResult
        static func expectOneVoice(_ note: Note?, sourceLocation: SourceLocation = #_sourceLocation) -> String? {
            let ids = Set(note?.transcript.map(\.speakerID) ?? [])
            #expect(note?.transcript.isEmpty == false, sourceLocation: sourceLocation)
            #expect(ids.count == 1, "one speaker: \(ids)", sourceLocation: sourceLocation)
            guard ids.count == 1, let only = ids.first, let id = only else { return nil }
            #expect(id.hasSuffix("_1") && UUID(uuidString: String(id.dropLast(2))) != nil,
                    "the run's first speaker id, never a fixed one: \(id)", sourceLocation: sourceLocation)
            let voice = NoteSpeaker(id: id, name: DefaultLabels.placeholder(1))
            #expect(note?.transcript.allSatisfy { $0.speaker == voice.name } == true, sourceLocation: sourceLocation)
            #expect(note?.speakers == [voice], sourceLocation: sourceLocation)
            #expect(note?.versions?.last?.speakers == [voice], "the version holds the one voice too",
                    sourceLocation: sourceLocation)
            return id
        }

        // ports: TranscriptionJobTest#provenanceWithoutTheDiarizerEqualsThe010Record (every word is spk_1)
        @Test func withoutTheSpeakerStepEveryPassageIsSpeakerOne() async throws {
            let off = try await Harness(settings: Self.off)
            #expect(await off.run().outcome == .done)
            let note = await off.note()
            Self.expectOneVoice(note)
            #expect(note?.speakerAnalysisFailure == nil)
            #expect(off.provenance(of: note)?.speakerDiarization == nil)

            // The speaker models declined (missing, no consent): the same.
            let declined = try await Harness(analyzer: FakeAnalyzer(modelIdentity: nil),
                                             settings: JobSettings(allowSpeechDownload: true, identifySpeakers: true,
                                                                   allowSpeakerDownload: false))
            #expect(await declined.run().outcome == .done)
            #expect(declined.applied.isEmpty)
            Self.expectOneVoice(await declined.note())
        }

        @Test func aSpeakerStepReplacesTheOneVoice() async throws {
            let analyzer = FakeAnalyzer(analysis: Self.twoSpeakers)
            let h = try await Harness(analyzer: analyzer)
            #expect(await h.run().outcome == .done)
            let note = try #require(await h.note())
            #expect(Set(note.transcript.compactMap(\.speakerID)) == ["a", "b"])
            #expect(note.transcript.allSatisfy { $0.speakerID != nil })
            #expect(analyzer.analyzedWords.first?.count == 70, "the analysis reads the saved words")
        }

        /// Identify speakers on a note left in one voice diarizes it as on a note without speakers.
        @Test func identifySpeakersOnTheOneVoiceTellsTheSpeakersApart() async throws {
            let analyzer = FakeAnalyzer(analysis: Self.twoSpeakers)
            let h = try await Harness(analyzer: analyzer, settings: Self.off)
            #expect(await h.run().outcome == .done)
            Self.expectOneVoice(await h.note())
            #expect(analyzer.analyzeCount == 0)

            #expect(await h.run(kind: .speakersOnly).outcome == .done)
            let note = try #require(await h.note())
            #expect(h.applied.count == 1)
            #expect(analyzer.analyzedWords.first?.count == 70)
            #expect(Set(note.transcript.compactMap(\.speakerID)) == ["a", "b"])
        }

        /// A transcribe-again run without speakers leaves its words in one voice, its own version.
        @Test func transcribeAgainWithoutSpeakersIsANewOneVoiceVersion() async throws {
            let off = try await Harness(settings: Self.off)
            _ = try await off.notes.mutate(off.noteID) { note in
                note.transcript = [TranscriptSegment(text: "Older", start: 0, end: 70, speakerID: "a")]
                note.speakers = [NoteSpeaker(id: "a", name: "Anna")]
                note.refreshSpeakerLabels()
            }
            #expect(await off.run().outcome == .done)
            let note = await off.note()
            Self.expectOneVoice(note)
            #expect(note?.versions?.map(\.kind) == [.previous, .transcription])
            #expect(note?.versions?.first?.speakers.map(\.name) == ["Anna"], "the transcript before keeps its names")
        }

        /// Transcribe again without a speaker step gives the new words a voice of their own: a new id, labelled
        /// "Speaker 1", that inherits neither the name nor the saved voice the earlier run's voice got (D56).
        @Test func eachRunWithoutTheSpeakerStepHasItsOwnVoice() async throws {
            let off = try await Harness(settings: Self.off)
            #expect(await off.run().outcome == .done)
            let first = try #require(Self.expectOneVoice(await off.note()))
            let anna = UUID()
            _ = try await off.notes.mutate(off.noteID) { note in
                note.renameSpeaker(first, name: "Anna")
                note.speakers?[0].match = .confirmed(voice: anna, score: 0.9)
                note.saveCurrentVersion(.previous)
            }

            #expect(await off.run().outcome == .done)
            let note = try #require(await off.note())
            let second = try #require(Self.expectOneVoice(note))
            #expect(second != first, "a new id for the new run")
            #expect(note.speakers?.first?.match == .unmatched)
            #expect(!(note.speakers ?? []).contains { $0.name == "Anna" }, "the earlier run's name stays with it")
            let earlier = try #require(note.versions?.first { $0.speakers.contains { $0.id == first } })
            #expect(earlier.speakers.map(\.name) == ["Anna"], "the earlier version keeps its name")
            #expect(earlier.segments.allSatisfy { $0.speakerID == first })
        }
    }
}
