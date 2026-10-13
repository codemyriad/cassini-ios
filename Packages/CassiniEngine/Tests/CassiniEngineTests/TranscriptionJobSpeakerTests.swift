import Foundation
import Synchronization
import Testing
@testable import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

extension TranscriptionJobTests {
    /// The speaker step after the words: its failures, its provenance and speakers-only jobs.
    @Suite struct Speakers {
        // ports: TranscriptionJobTest#aDiarizerFailureDegradesToOneVoice
        @Test func aSpeakerFailureDegradesToOneVoice() async throws {
            let h = try await Harness(analyzer: FailingAnalyzer())
            let (outcome, events) = await h.run()
            #expect(outcome == .done)
            #expect(events.contains(.speakersUnavailable))
            #expect(!events.contains { $0.stage == .matching })
            let note = try #require(await h.note())
            #expect(note.speakerAnalysisFailure == .speakers)
            #expect(note.transcript.flatMap(\.words).count == 70)
            #expect(h.provenance(of: note)?.speakerDiarization == nil)
            #expect(h.applied.isEmpty)
        }

        @Test func aFailedSpeakerSaveAlsoDegradesToOneVoice() async throws {
            let h = try await Harness()
            h.host.failsApplying = true
            #expect(await h.run().outcome == .done)
            #expect(await h.note()?.speakerAnalysisFailure == .speakers)
        }

        // ports: TranscriptionJobTest#provenanceEqualsThe010Record (adapted: the iOS record; ProvenanceGoldenTests pins
        // the key sets against Android's)
        @Test func provenanceCarriesTheEngineAndTheSpeakerRecord() async throws {
            let analysis = SpeakerAnalysis(
                turns: [.init(speakerID: "a", start: 0, end: 30), .init(speakerID: "b", start: 30, end: 70),
                        .init(speakerID: "a", start: 70, end: 71)],
                prints: [SpeakerPrint(speakerID: "a", model: "pyannote-community-1:abc123", vector: [1, 0], speechSeconds: 30)],
                backend: "FluidAudio test", modelRevision: "rev1", elapsedMs: 640)
            let h = try await Harness(analyzer: FakeAnalyzer(analysis: analysis))
            #expect(await h.run().outcome == .done)
            let provenance = try #require(h.provenance(of: await h.note()))
            let record = provenance.record()
            #expect(record.keys == ["backend", "engine", "model", "device", "source", "version", "language", "x-inferenceMs",
                                    "x-segmentation", "x-resumedFromMs", "x-speakerDiarization", "x-speakerIdentification"])
            #expect(record["engine"]?.string == "apple-speechtranscriber")
            #expect(record["backend"]?.string == TranscriptProvenance.appleSpeechBackend)
            #expect(record["model"]?.string == "Fake SpeechTranscriber it-IT", "what the transcriber names its model")
            #expect(record["device"]?.string == RunDevice.current().description)
            #expect(record["source"]?.string == "recording")
            #expect(record["language"]?.string == "it-IT")
            #expect(record["x-segmentation"]?.string == TranscriptProvenance.appleSegmentation)
            let diarization = try #require(record["x-speakerDiarization"]?.object)
            #expect(diarization.keys == ["backend", "model", "modelRevision", "modelSha256", "elapsedMs", "turnCount",
                                         "speakerCount", "assignment", "sourceSeparation"])
            #expect(diarization["backend"]?.string == "FluidAudio test")
            #expect(diarization["model"]?.string == "pyannote-community-1")
            #expect(diarization["modelSha256"]?.string == "abc123")
            #expect(diarization["modelRevision"]?.string == "rev1")
            #expect(diarization["elapsedMs"] == .int(640))
            #expect(diarization["sourceSeparation"] == .bool(false))
            #expect(provenance.speakerDiarization?.turnCount == 3)
            #expect(provenance.speakerDiarization?.speakerCount == 2)
            let identification = try #require(provenance.speakerIdentification)
            #expect(identification.model == "pyannote-community-1" && identification.sha256 == "abc123")
            #expect(identification.dim == 2 && identification.speakersWithPrints == 1)
            #expect(identification.autoApplied == 0 && identification.suggested == 0, "the fake host matches nobody")
            #expect(h.applied.map(\.generation) == [7])
        }

        /// The counts come from the speakers as the note took them: named from a saved voice, or only offered one.
        @Test func theIdentificationCountsTheMatchesTheNoteTook() throws {
            let prints = ["a", "b", "c"].map { SpeakerPrint(speakerID: $0, model: "m:sha", vector: [1, 0, 0], speechSeconds: 9) }
            let analysis = SpeakerAnalysis(turns: [], prints: prints)
            var note = Note(title: "Three")
            note.transcript = ["a", "b", "c", "d"].enumerated().map { index, id in
                TranscriptSegment(text: id, start: Double(index), end: Double(index) + 1, speakerID: id)
            }
            let voice = UUID()
            note.speakers = [NoteSpeaker(id: "a", name: "Luca"), NoteSpeaker(id: "b", name: "Sara"),
                             NoteSpeaker(id: "c", name: "Speaker 3"), NoteSpeaker(id: "d", name: "Speaker 4"),
                             NoteSpeaker(id: "gone", name: "Elsewhere")]
            note.speakers?[0].match = .auto(voice: voice, score: 0.9)
            note.speakers?[1].match = .confirmed(voice: UUID(), score: 0.9)
            note.speakers?[2].match = .suggested(voice: UUID(), score: 0.7)
            note.speakers?[4].match = .auto(voice: UUID(), score: 0.9)
            let identification = try #require(TranscriptionJob.identification(analysis, note))
            #expect(identification.speakersWithPrints == 3)
            #expect(identification.autoApplied == 2)
            #expect(identification.suggested == 1)
            #expect(identification.dim == 3 && identification.model == "m" && identification.sha256 == "sha")
            #expect(identification.autoThreshold == 0.85 && identification.suggestThreshold == 0.65
                    && identification.margin == 0.12)
            #expect(TranscriptionJob.identification(SpeakerAnalysis(turns: [], prints: []), note) == nil, "no prints")
        }

        @Test func withoutTheSpeakerStepTheWordsAreSavedAlone() async throws {
            let h = try await Harness(settings: JobSettings(allowSpeechDownload: true, identifySpeakers: false,
                                                           allowSpeakerDownload: true))
            let (outcome, events) = await h.run()
            #expect(outcome == .done)
            #expect(events.contains(.namingClosed(matching: false)))
            #expect(!events.contains { $0.stage == .speakers })
            #expect(events.compactMap(\.started).first?.speakers == false)
            #expect(h.applied.isEmpty)
        }

        @Test func aSpeakersOnlyJobLeavesTheWordsAlone() async throws {
            let h = try await Harness()
            let words = [TranscriptSegment(text: "Kept", start: 0, end: 1)]
            _ = try await h.notes.mutate(h.noteID) { $0.transcript = words }
            let (outcome, events) = await h.run(kind: .speakersOnly)
            #expect(outcome == .done)
            #expect(h.transcriber.starts.isEmpty)
            #expect(await h.note()?.transcript == words)
            #expect(h.applied.count == 1)
            #expect(events.contains { $0.stage == .speakers })
        }

        @Test func aSpeakersOnlyJobEndsWithTheSpeakerModelDownloadFailure() async throws {
            let failure = SpeakerAnalysisError.download(.notEnoughStorage, requiredFreeBytes: 54_000_000)
            let h = try await Harness(analyzer: InstallFailingAnalyzer(failure: failure))
            let (outcome, _) = await h.run(kind: .speakersOnly)
            #expect(outcome == .downloadFailed(DownloadFailure(error: .notEnoughStorage, part: .speakers,
                                                               requiredFreeBytes: 54_000_000)))
            #expect(h.applied.isEmpty)
        }

        @Test func aTranscriptionWhoseSpeakerModelsFailToDownloadKeepsItsWordsInOneVoice() async throws {
            let h = try await Harness(analyzer: InstallFailingAnalyzer(failure: .download(.noConnection, requiredFreeBytes: 0)))
            let (outcome, events) = await h.run()
            #expect(outcome == .done)
            #expect(events.contains(.speakersUnavailable))
            #expect(await h.note()?.speakerAnalysisFailure == .speakers)
        }

        @Test func aStopInTheSpeakerStepKeepsTheWordsAndResumesWithTheSpeakers() async throws {
            let analyzer = FakeAnalyzer(suspends: true)
            let h = try await Harness(analyzer: analyzer)
            let stop = StopSignal()
            let running = Task { await h.run(stop: stop) }
            while analyzer.analyzeCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
            stop.stop(.pause(.user))
            // The analysis ends at its next check once the stop cancelled it.
            try await Task.sleep(for: .milliseconds(100))
            analyzer.resume()
            let (outcome, _) = await running.value
            #expect(outcome == .paused(.user))
            #expect(try h.files.load(h.noteID)?.wordsComplete == true)
            #expect(await h.note()?.transcript.flatMap(\.words).count == 70, "the words are in the note")

            let (resumed, _) = await h.run()
            #expect(resumed == .done)
            #expect(h.transcriber.starts == [0], "the words are not transcribed again")
            #expect(h.applied.count == 1)
            #expect(!h.files.exists(h.noteID))
        }
    }
}
