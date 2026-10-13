import CassiniCore
import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// A gate a test opens to let a pretend import finish.
private actor Gate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    func wait() async {
        guard !open else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor @Suite struct ImportTrackerTests {
    let clock = FakeClock()

    @Test func importsRunSideBySideAndEachIsShownWhileItRuns() async {
        let tracker = ImportTracker(clock: clock)
        let gate = Gate()
        let first = tracker.start(displayName: "uno.m4a") { await gate.wait(); return .created(UUID()) }
        let second = tracker.start(displayName: "due.m4a") { await gate.wait(); return .created(UUID()) }
        let third = tracker.start(displayName: "tre.m4a") { await gate.wait(); return .created(UUID()) }

        #expect(tracker.running == ["uno.m4a", "due.m4a", "tre.m4a"])
        await gate.release()
        let outcomes = [await first.value, await second.value, await third.value]

        #expect(outcomes.allSatisfy { $0?.noteID != nil })
        #expect(tracker.running.isEmpty)
        #expect(tracker.failure == nil)
    }

    @Test func aRejectedImportIsShownUntilDismissedOrTheNextImport() async {
        let tracker = ImportTracker(clock: clock)
        _ = await tracker.start(displayName: "huge.wav") { .rejected(.tooLarge) }.value
        #expect(tracker.failure == ImportFailureFact(displayName: "huge.wav", kind: .tooLarge, at: clock.now))

        tracker.dismissFailure()
        #expect(tracker.failure == nil)

        _ = await tracker.start(displayName: "full.wav") { .rejected(.noSpace(bytesNeeded: 42)) }.value
        #expect(tracker.failure?.kind == .noSpace(bytesNeeded: 42))
        let next = tracker.start(displayName: "ok.wav") { .existing(UUID()) }
        #expect(tracker.failure == nil)
        _ = await next.value
        #expect(tracker.failure == nil)
    }

    @Test func anImportThatThrowsIsShownAsCannotOpenAndACancelledOneIsNotShown() async {
        let tracker = ImportTracker(clock: clock)
        let failed = await tracker.start(displayName: "x") { throw CocoaError(.fileReadUnknown) }.value
        #expect(failed == nil)
        #expect(tracker.failure?.kind == .cannotOpen)

        let cancelled = await tracker.start(displayName: "y") { throw CancellationError() }.value
        #expect(cancelled == nil)
        #expect(tracker.failure == nil)
        #expect(tracker.running.isEmpty)
    }

    @Test func twoImportsWithOneNameEndOneAtATime() async {
        let tracker = ImportTracker(clock: clock)
        let gate = Gate()
        let slow = tracker.start(displayName: "same.m4a") { await gate.wait(); return .created(UUID()) }
        _ = await tracker.start(displayName: "same.m4a") { .created(UUID()) }.value
        #expect(tracker.running == ["same.m4a"])
        await gate.release()
        _ = await slow.value
        #expect(tracker.running.isEmpty)
    }
}

@Suite struct PortableExportServiceTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func transcribed(_ title: String) -> Note {
        var note = Note(title: title)
        note.language = "en_US"
        note.transcript = [TranscriptSegment(text: "Hello there", start: 0, end: 1.5, speaker: "Alex", speakerID: "a")]
        note.speakers = [NoteSpeaker(id: "a", name: "Alex")]
        return note
    }

    @Test func aTitleLikeAnIntermediateFileDoesNotCollideWithIt() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let playable = folder.appendingPathComponent("audio.m4a")
        try Data(ImportFixtures.m4a).write(to: playable)
        var note = transcribed("encoded")
        var earlier = TranscriptVersion(kind: .transcription, segments: [TranscriptSegment(text: "Hi", start: 0, end: 1, speakerID: "a")],
                                        speakers: note.speakers ?? [])
        earlier.portableID = nil
        note.versions = [earlier]

        let output = try await PortableExportService(audio: FakeAudioProcessing(duration: 2), provenance: FakeProvenance())
            .export(note, original: playable, playable: playable, into: folder, filename: "encoded")

        #expect(output.lastPathComponent == "encoded.opus")
        let document = CassiniDocument.read(output)
        #expect(document.state == .ok)
        #expect(document.title == "encoded")
        #expect(document.variants.count == 2)
        #expect(document.selected()?.transcript?.language == "en-US")
        #expect(document.selected()?.transcript?.words.map(\.text) == ["Hello", "there"])
        #expect(document.speakerLabel("a") == "Alex")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["audio.m4a", "encoded.opus"])
    }

    @Test func anImportedOpusIsUsedAsItIsAndAFailureLeavesNothing() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("source.opus")
        let opus = try ImportFixtures.opus(packets: 100)
        try Data(opus).write(to: original)

        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance())
            .export(transcribed("Talk"), original: original, playable: original, into: folder, filename: "Talk")
        #expect(try OggOpus.scan(output).digest() == OggOpus.scan(original).digest())
        #expect(try Data(contentsOf: original) == Data(opus))

        await #expect(throws: PortableExportError.noTranscript) {
            try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance())
                .export(Note(title: "Empty"), original: original, playable: original, into: folder, filename: "Empty")
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["Talk.opus", "source.opus"])
    }

    /// The record an export wrote for `variant`: `provenance.speechToText.<variant>`.
    private func processing(_ document: CassiniDocument, _ variant: String?) -> JSONObject? {
        variant.flatMap { document.manifest?["provenance"]?.object?["speechToText"]?.object?[$0]?.object }
    }

    private func twoSpeakers() -> Note {
        var note = Note(title: "Two")
        note.language = "en-US"
        note.transcript = [
            TranscriptSegment(text: "Hello", start: 0, end: 1, speaker: "Alex", speakerID: "a",
                              words: [TimedWord(text: "Hello", start: 0, end: 1)]),
            TranscriptSegment(text: "there", start: 1.2, end: 2, speaker: "Sam", speakerID: "b",
                              words: [TimedWord(text: "there", start: 1.2, end: 2)]),
        ]
        note.speakers = [NoteSpeaker(id: "a", name: "Alex"), NoteSpeaker(id: "b", name: "Sam")]
        return note
    }

    private func runRecord(_ note: Note) -> ProvenanceRecord {
        var record = ProvenanceRecord(provenance: TranscriptProvenance(language: "en-US", inferenceMs: 1_500, resumedFromMs: 600),
                                      transcript: note.transcript)
        record.addSpeakers(.init(model: "diarizer", sha: "abc", turnCount: 2, speakerCount: 2), transcript: note.transcript)
        return record
    }

    @Test func theRunsProvenanceGoesIntoTheExportWithAndroidsKeys() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("source.opus")
        try Data(ImportFixtures.opus(packets: 100)).write(to: original)
        let note = twoSpeakers()

        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance([note.id: runRecord(note)]))
            .export(note, original: original, playable: original, into: folder, filename: "Two")

        let document = CassiniDocument.read(output)
        let record = try #require(processing(document, document.defaultId))
        #expect(record["engine"] == .string(TranscriptProvenance.appleSpeech))
        #expect(record["x-inferenceMs"] == .int(1_500))
        #expect(record["x-resumedFromMs"] == .int(600))
        let diarization = try #require(record["x-speakerDiarization"]?.object)
        #expect(diarization["model"] == .string("diarizer"))
        #expect(diarization["turnCount"] == .int(2))
        #expect(record["x-speakerMerges"] == nil)
    }

    @Test func wordsThatAreNotTheRunsAreRecordedAsEditedByHand() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("source.opus")
        try Data(ImportFixtures.opus(packets: 100)).write(to: original)
        var note = twoSpeakers()
        let record = runRecord(note)
        note.transcript[1].text = "everyone"
        note.transcript[1].words = []

        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance([note.id: record]))
            .export(note, original: original, playable: original, into: folder, filename: "Two")

        let document = CassiniDocument.read(output)
        #expect(processing(document, document.defaultId) == ExportProvenance.userEdited)
    }

    // ports: DocumentRepositoryTest#aMergeCreatesVersionNPlusOneAndSelectsIt
    @Test func aMergedVersionRecordsItsAliasesAndTheVariantItCameFrom() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("source.opus")
        try Data(ImportFixtures.opus(packets: 100)).write(to: original)
        var note = twoSpeakers()
        let record = runRecord(note)
        note.mergeSpeaker("b", into: "a")

        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance([note.id: record]))
            .export(note, original: original, playable: original, into: folder, filename: "Two")

        let document = CassiniDocument.read(output)
        #expect(document.variants.count == 2)
        let before = try #require(document.variants.first?.id)
        #expect(processing(document, before)?["x-speakerMerges"] == nil)
        let merged = try #require(processing(document, document.defaultId))
        #expect(merged["x-speakerMerges"] == .object(JSONObject([("b", .string("a"))])))
        #expect(merged["x-speakerAssignmentEditedBy"] == .string("user"))
        #expect(merged["x-derivedFromTranscript"] == .string(before))
        #expect(merged["x-inferenceMs"] == .int(1_500), "a merge keeps the run's words")
        #expect(merged["x-speakerDiarization"] != nil, "a merge only removes speaker ids")
        #expect(Set(document.selected()?.transcript?.words.map(\.speaker) ?? []) == ["a"])
    }
    @Test func aMergedVersionEditedAfterwardsKeepsTheMergeAliases() async throws {
        let folder = try folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("source.opus")
        try Data(ImportFixtures.opus(packets: 100)).write(to: original)
        var note = twoSpeakers()
        let record = runRecord(note)
        note.mergeSpeaker("b", into: "a")
        let passage = try #require(note.transcript.last)
        note.revisePassage(passage, to: passage.revised(text: "everyone", speakerID: "a", speakers: note.speakers ?? []),
                           stamp: VersionStamp(date: Date()))

        let output = try await PortableExportService(audio: FakeAudioProcessing(), provenance: FakeProvenance([note.id: record]))
            .export(note, original: original, playable: original, into: folder, filename: "Two")

        let document = CassiniDocument.read(output)
        #expect(document.variants.count == 3)
        let before = try #require(document.variants.first?.id)
        let edited = try #require(processing(document, document.defaultId))
        #expect(edited["kind"] == .string("user-edited"), "the edit changed the run's words")
        #expect(edited["x-speakerMerges"] == .object(JSONObject([("b", .string("a"))])))
        #expect(edited["x-derivedFromTranscript"] == .string(before))
    }
}
