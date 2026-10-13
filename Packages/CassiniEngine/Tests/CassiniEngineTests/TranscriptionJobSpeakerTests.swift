import Foundation
import Synchronization
import Testing
import CassiniEngine
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

        // ports: TranscriptionJobTest#provenanceEqualsThe010Record (adapted: the iOS record)
        @Test func provenanceCarriesTheEngineAndTheSpeakerRecord() async throws {
            let analysis = SpeakerAnalysis(
                turns: [.init(speakerID: "a", start: 0, end: 30), .init(speakerID: "b", start: 30, end: 70),
                        .init(speakerID: "a", start: 70, end: 71)],
                prints: [SpeakerPrint(speakerID: "a", model: "pyannote-community-1:abc123", vector: [1, 0], speechSeconds: 30)])
            let h = try await Harness(analyzer: FakeAnalyzer(analysis: analysis))
            #expect(await h.run().outcome == .done)
            let provenance = try #require(h.provenance(of: await h.note()))
            let record = provenance.record()
            #expect(record.keys == ["engine", "language", "x-inferenceMs", "x-resumedFromMs", "x-speakerDiarization"])
            #expect(record["engine"]?.string == "apple-speechtranscriber")
            #expect(record["language"]?.string == "it-IT")
            let diarization = try #require(record["x-speakerDiarization"]?.object)
            #expect(diarization.keys == ["backend", "model", "sha", "turnCount", "speakerCount"])
            #expect(diarization["backend"]?.string == "fluidaudio")
            #expect(diarization["model"]?.string == "pyannote-community-1")
            #expect(diarization["sha"]?.string == "abc123")
            #expect(provenance.speakerDiarization?.turnCount == 3)
            #expect(provenance.speakerDiarization?.speakerCount == 2)
            #expect(h.applied.map(\.generation) == [7])
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
