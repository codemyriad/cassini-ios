import CassiniCore
import CryptoKit
import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// Free space that a test scripts: each reading asks `bytes` with the reading's index.
private final class ScriptedStorage: StorageProbe {
    private let readings = Atomic(0)
    let bytes: @Sendable (Int) -> Int64
    init(_ bytes: @escaping @Sendable (Int) -> Int64) { self.bytes = bytes }
    convenience init(always value: Int64) { self.init { _ in value } }
    func availableBytes(at url: URL) -> Int64 { bytes(readings.add(1, ordering: .relaxed).oldValue) }
}

/// Audio files for the tests: containers the fake probe recognises, Opus silence and Cassini documents.
enum ImportFixtures {
    static let duration: TimeInterval = 15.84
    static let m4a = [0, 0, 0, 0x18] + Array("ftypM4A ".utf8) + [UInt8](repeating: 0, count: 12) + Array("moov".utf8) + [UInt8](repeating: 7, count: 2_000)
    static let mp3 = Array("ID3".utf8) + [4, 0, 0, 0, 0, 0, 0] + [UInt8](repeating: 9, count: 3_000)
    static let wav = Array("RIFF".utf8) + [0, 0, 0, 0] + Array("WAVEfmt ".utf8) + [UInt8](repeating: 1, count: 1_000)

    static func opus(packets: Int = 792, comments: [String] = []) throws -> [UInt8] {
        let head = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let tags = CassiniDocument.tagsPacket(comments)
        let stream = OggOpus.Stream(head: head, tags: tags, audio: Array(repeating: [0xF8, 0xFF, 0xFE], count: packets),
                                    finalGranule: Int64(packets * 960), validFraming: true)
        return try OggOpus.mux(stream, tags: tags)
    }

    static func document(_ text: String, title: String) throws -> [UInt8] {
        let words = text.split(separator: " ").enumerated().map { index, word in
            Word("S1", Int64(index * 500), Int64(index * 500 + 400), String(word))
        }
        return try CassiniDocument.create(opus(), transcript: Transcript(words, language: "it"), title: title,
                                          processing: JSONObject(), speakerLabels: ["S1": "Ada"])
    }
}

/// A library root, a folder of files to import and the import's collaborators.
private final class ImportHarness: Sendable {
    let root: URL
    let inputs: URL
    let store: NoteStore
    let audio = FakeAudioProcessing(duration: ImportFixtures.duration)
    let clock = FakeClock()

    init() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-import-\(UUID().uuidString)")
        root = base.appendingPathComponent("notes")
        inputs = base.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        store = try NoteStore(root: root)
    }

    deinit { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }

    func importer(storage: any StorageProbe = ScriptedStorage(always: 64 << 30),
                  sizeOf: @escaping @Sendable (URL) -> Int64? = CoordinatedFileImporter.reportedSize) -> ImportService {
        ImportService(notes: store, files: CoordinatedFileImporter(storage: storage, sizeOf: sizeOf), audio: audio,
                      storage: storage, clock: clock)
    }

    func run(_ url: URL, _ service: ImportService? = nil) async throws -> ImportOutcome {
        try await (service ?? importer()).importFile(url, language: "en-US", fallbackTitle: ImportTitles.fallbackTitle)
    }

    func input(_ bytes: [UInt8], _ name: String) throws -> URL {
        let url = inputs.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    func noteDirs() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).sorted()
    }

    func files(_ id: UUID) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: store.directory(for: id).path)) ?? [])
            .filter { $0 != NoteRepository.metadataFilename }.sorted()
    }

    func created(_ outcome: ImportOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> UUID {
        guard case .created(let id) = outcome else {
            Issue.record("expected created, got \(outcome)", sourceLocation: sourceLocation)
            throw CancellationError()
        }
        return id
    }

    func note(_ id: UUID) async throws -> Note { try #require(await store.note(id)) }

    @discardableResult
    func assertPlain(_ id: UUID, file: String, duration: TimeInterval, title: String,
                     sourceLocation: SourceLocation = #_sourceLocation) async throws -> Note {
        let note = try await note(id)
        #expect(note.origin == .imported, sourceLocation: sourceLocation)
        #expect(note.audioFilename == file, sourceLocation: sourceLocation)
        #expect(abs(note.duration - duration) < 0.001, sourceLocation: sourceLocation)
        #expect(note.title == title, sourceLocation: sourceLocation)
        #expect(note.document == nil, sourceLocation: sourceLocation)
        #expect(files(id) == [note.originalAudioFilename, note.audioFilename].compactMap { $0 }.sorted(), sourceLocation: sourceLocation)
        return note
    }
}

private func sha256(_ url: URL) throws -> String {
    OggOpus.hex(Array(SHA256.hash(data: try Data(contentsOf: url))))
}

@Suite struct ImportServiceTests {
    @Test func aPlainFileKeepsItsBytesHashAndImportTime() async throws {
        let h = try ImportHarness()
        let url = try h.input(ImportFixtures.m4a, "Riunione di lunedì.m4a")

        let id = try h.created(try await h.run(url))

        let note = try await h.assertPlain(id, file: "source.m4a", duration: ImportFixtures.duration, title: "Riunione di lunedì")
        #expect(note.sourceSha256 == (try sha256(url)))
        #expect(note.createdAt == h.clock.now)
        #expect(note.status == .audioOnly)
        #expect(note.waveform == [0.5, 0.5])
        #expect(note.language == "en-US")
        #expect(try Data(contentsOf: h.store.audioURL(for: note)) == Data(ImportFixtures.m4a))
        #expect(try Data(contentsOf: url) == Data(ImportFixtures.m4a))
    }

    // ports: ImportRepositoryTest#aPlainOggOpusBecomesSourceOpusTitledByItsDisplayName
    @Test func aPlainOggOpusBecomesSourceOpusTitledByItsDisplayName() async throws {
        let h = try ImportHarness()
        let id = try h.created(try await h.run(try h.input(try ImportFixtures.opus(), "intervista.opus")))

        let note = try await h.assertPlain(id, file: ImportService.playbackFilename, duration: 15.84, title: "intervista")
        #expect(note.originalAudioFilename == ImportService.plainOpusFilename)
        #expect(note.audio == .plain)
        #expect(note.duration > 15)
    }

    // ports: ImportRepositoryTest#m4aAndMp3GoThroughTheProbe
    @Test func m4aAndMp3GoThroughTheProbe() async throws {
        let h = try ImportHarness()
        let m4a = try h.created(try await h.run(try h.input(ImportFixtures.m4a, "memo.m4a")))
        let mp3 = try h.created(try await h.run(try h.input(ImportFixtures.mp3, "podcast.MP3")))

        try await h.assertPlain(m4a, file: "source.m4a", duration: ImportFixtures.duration, title: "memo")
        try await h.assertPlain(mp3, file: "source.mp3", duration: ImportFixtures.duration, title: "podcast")
        #expect(h.audio.inspections == 2)
    }

    // ports: ImportRepositoryTest#aMislabelledFileGetsTheExtensionOfWhatItIs
    @Test func aMislabelledFileGetsTheExtensionOfWhatItIs() async throws {
        // An MP3 named .opus must never become source.opus, which the pipeline reads as Ogg Opus.
        let h = try ImportHarness()
        let id = try h.created(try await h.run(try h.input(ImportFixtures.mp3, "song.opus")))
        try await h.assertPlain(id, file: "source.mp3", duration: ImportFixtures.duration, title: "song")
    }

    @Test func aWavIsReadByAVFoundationWhateverItsSampleFormat() async throws {
        // Android accepts 16-bit PCM WAV only; AVFoundation decodes 24-bit and float WAV too, so iOS accepts them.
        let h = try ImportHarness()
        let id = try h.created(try await h.run(try h.input(ImportFixtures.wav, "24bit.wav")))
        try await h.assertPlain(id, file: "source.wav", duration: ImportFixtures.duration, title: "24bit")
    }

    // ports: ImportRepositoryTest#aCassiniDocumentIsVerifiedOnceAndOpensFromTheCache
    @Test func aCassiniDocumentIsVerifiedOnceAndOpensFromTheCache() async throws {
        let h = try ImportHarness()
        let bytes = try ImportFixtures.document("buongiorno a tutti oggi parliamo della consegna di giovedì", title: "Seduta del consiglio")
        let url = try h.input(bytes, "export.opus")

        let id = try h.created(try await h.run(url))

        let note = try await h.note(id)
        let manifest = try #require(CassiniDocument.read(bytes).manifest)
        #expect(note.origin == .importedDocument)
        #expect(note.originalAudioFilename == ImportService.documentFilename)
        #expect(note.audioFilename == ImportService.playbackFilename)
        #expect(note.title == "Seduta del consiglio")
        #expect(note.document == DocumentInfo(state: .ok, vendor: CassiniDocument.vendor,
                                              meetingID: try manifest.object("meeting").string("id")))
        #expect(note.sourceSha256 == (try sha256(url)))
        let created = try manifest.object("meeting").string("createdAtUtc")
        #expect(note.createdAt == (try Date(created, strategy: .iso8601)))
        #expect(note.duration == Double(try manifest.object("meeting").number("durationMs")) / 1000)
        #expect(note.text == "buongiorno a tutti oggi parliamo della consegna di giovedì")
        #expect(note.speakers?.map(\.name) == ["Ada"])
        #expect(note.status == .ready)
        #expect(note.language == "it")
        #expect(!ImportedNote.wantsTranscription(note))
        // The import recorded what it read: the next launch reads nothing but note.json.
        let reloaded = try NoteStore(root: h.root)
        try await reloaded.load()
        #expect(await reloaded.note(id) == note)
        #expect(try Data(contentsOf: h.store.originalAudioURL(for: note)) == Data(bytes))
    }

    // ports: ImportRepositoryTest#aDocumentWithBrokenMetadataIsStillADocument
    @Test func aDocumentWithBrokenMetadataIsStillADocument() async throws {
        let h = try ImportHarness()
        let bytes = try ImportFixtures.document("una prova", title: "Prova")
        let comments = CassiniDocument.read(bytes).comments.map { $0.hasPrefix("CASSINI_PROFILE=") ? "CASSINI_PROFILE=other" : $0 }
        let broken = try OggOpus.mux(OggOpus.read(bytes), tags: CassiniDocument.tagsPacket(comments))

        let id = try h.created(try await h.run(try h.input(broken, "rotto.opus")))

        let note = try await h.note(id)
        #expect(note.origin == .importedDocument)
        #expect(note.document?.state == .invalidMetadata)
        #expect(note.title == "rotto")
        #expect(note.duration > 15)
        #expect(note.transcript.isEmpty)
        #expect(ImportedNote.wantsTranscription(note))
    }

    @Test func aStaleDocumentKeepsItsTranscriptAndItsWarning() async throws {
        let h = try ImportHarness()
        let bytes = try ImportFixtures.document("audio cambiato", title: "Vecchia")
        // The metadata of one recording over other audio: SPEC.md's stale-audio lifecycle failure.
        let stale = try OggOpus.mux(OggOpus.read(ImportFixtures.opus(packets: 100)), tags: OggOpus.read(bytes).tags)

        let id = try h.created(try await h.run(try h.input(stale, "vecchia.opus")))

        let note = try await h.note(id)
        #expect(note.document?.state == .staleAudio)
        #expect(note.document?.warnings.contains("audio-digest-mismatch") == true)
        #expect(DocumentTrust.of(note) == .audioChanged)
        #expect(note.text == "audio cambiato")
        #expect(note.title == "Vecchia")
        #expect(!ImportedNote.wantsTranscription(note))
    }

    @Test func aNewerFormatIsADocumentThatIsNotTranscribed() async throws {
        let h = try ImportHarness()
        let bytes = try ImportFixtures.opus(comments: ["CASSINI_FORMAT=org.cassini.portable-meeting/99"])
        let id = try h.created(try await h.run(try h.input(bytes, "futuro.opus")))
        let note = try await h.note(id)
        #expect(note.document?.state == .unknownFormat)
        #expect(note.audio == .plain)
        #expect(!ImportedNote.wantsTranscription(note))
    }

    // ports: ImportRepositoryTest#somethingThatIsNotAudioIsRejectedAsOpen
    @Test func somethingThatIsNotAudioIsRejectedAsOpen() async throws {
        let h = try ImportHarness()
        let text = try h.input(Array("not audio at all".utf8), "notes.txt")
        let missing = h.inputs.appendingPathComponent("missing.mp3")

        #expect(try await h.run(text) == .rejected(.cannotOpen))
        #expect(try await h.run(missing) == .rejected(.cannotOpen))
        #expect(h.noteDirs().isEmpty)
        #expect(await h.store.all().isEmpty)
    }

    @Test func anOggOpusFileWithoutAudioIsRejectedAsOpen() async throws {
        let h = try ImportHarness()
        var bytes = try ImportFixtures.opus()
        bytes.removeLast(bytes.count - 200)
        #expect(try await h.run(try h.input(bytes, "cut.opus")) == .rejected(.cannotOpen))
        #expect(h.noteDirs().isEmpty)
    }

    // ports: ImportRepositoryTest#theSameBytesTwiceGiveTheExistingLiveNote
    @Test func theSameBytesTwiceGiveTheExistingLiveNote() async throws {
        let h = try ImportHarness()
        let first = try h.created(try await h.run(try h.input(ImportFixtures.m4a, "a.m4a")))
        let again = try await h.run(try h.input(ImportFixtures.m4a, "another name.m4a"))

        #expect(again == .existing(first))
        #expect(h.noteDirs() == [first.uuidString])
        #expect(await h.store.all().count == 1)
    }

    // ports: ImportRepositoryTest#aTrashedNoteWithTheSameBytesIsIgnored
    @Test func aTrashedNoteWithTheSameBytesIsIgnored() async throws {
        let h = try ImportHarness()
        let first = try h.created(try await h.run(try h.input(ImportFixtures.mp3, "a.mp3")))
        let trashedAt = h.clock.now
        try await h.store.mutate(first) { $0.trashedAt = trashedAt }

        let second = try h.created(try await h.run(try h.input(ImportFixtures.mp3, "a.mp3")))

        #expect(first != second)
        #expect(h.noteDirs() == [first.uuidString, second.uuidString].sorted())
        #expect(try await h.note(first).sourceSha256 == h.note(second).sourceSha256)
    }

    // ports: ImportRepositoryTest#twoImportsOfOneFileAtOnceAddOneNote
    @Test func twoImportsOfOneFileAtOnceAddOneNote() async throws {
        let h = try ImportHarness()
        let url = try h.input(try ImportFixtures.opus(), "doppio.opus")
        let service = h.importer()
        let outcomes = try await withThrowingTaskGroup(of: ImportOutcome.self) { group in
            for _ in 1...4 { group.addTask { try await h.run(url, service) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }

        let created = outcomes.compactMap { if case .created(let id) = $0 { id } else { nil } }
        #expect(created.count == 1)
        let id = try #require(created.first)
        #expect(outcomes.allSatisfy { $0 == .created(id) || $0 == .existing(id) })
        #expect(h.noteDirs() == [id.uuidString])
    }

    // ports: ImportRepositoryTest#aFileOverTwoGibibytesIsRejectedBeforeTheCopy
    @Test func aFileOverFourGibibytesIsRejectedBeforeTheCopy() async throws {
        let h = try ImportHarness()
        let service = h.importer(sizeOf: { _ in Limits.maxImportBytes + 1 })

        let outcome = try await h.run(try h.input(ImportFixtures.m4a, "huge.m4a"), service)

        #expect(outcome == .rejected(.tooLarge))
        #expect(h.noteDirs().isEmpty)
    }

    // ports: ImportRepositoryTest#theCapHoldsDuringTheCopyWhenTheSizeIsUnknown
    @Test func theCapHoldsDuringTheCopyWhenTheSizeIsUnknown() async throws {
        let h = try ImportHarness()
        let importer = CoordinatedFileImporter(storage: ScriptedStorage(always: 64 << 30), sizeOf: { _ in nil })
        let source = try h.input(ImportFixtures.m4a, "huge.m4a")
        let target = h.inputs.appendingPathComponent("copy.tmp")

        await #expect(throws: FileImportError.tooLarge) {
            try await importer.copy(from: source, to: target, maxBytes: 1_000, reserveBytes: Limits.minFreeImportBytes)
        }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    // ports: ImportRepositoryTest#notEnoughSpaceIsRejectedWithTheBytesNeeded
    @Test func notEnoughSpaceIsRejectedWithTheBytesNeeded() async throws {
        let h = try ImportHarness()
        let size = Int64(ImportFixtures.m4a.count)
        let url = try h.input(ImportFixtures.m4a, "a.m4a")

        let outcome = try await h.run(url, h.importer(storage: ScriptedStorage(always: size + Limits.minFreeImportBytes - 1)))

        #expect(outcome == .rejected(.noSpace(bytesNeeded: size + Limits.minFreeImportBytes)))
        #expect(h.noteDirs().isEmpty)
        _ = try h.created(try await h.run(url, h.importer(storage: ScriptedStorage(always: size + Limits.minFreeImportBytes))))
    }

    private func long(_ h: ImportHarness) throws -> URL {
        try h.input(ImportFixtures.mp3 + [UInt8](repeating: 0, count: 9 << 20), "long.mp3")
    }

    // ports: ImportRepositoryTest#spaceRunningOutDuringTheCopyIsRejected
    @Test func spaceRunningOutDuringTheCopyIsRejected() async throws {
        // An unknown size skips the check before the copy; the copy checks every 8 MiB.
        let h = try ImportHarness()
        let service = h.importer(storage: ScriptedStorage(always: Limits.minFreeImportBytes - 1), sizeOf: { _ in nil })

        let outcome = try await h.run(try long(h), service)

        #expect(outcome.failure.map { if case .noSpace = $0 { true } else { false } } == true)
        #expect(h.noteDirs().isEmpty)
    }

    // ports: ImportRepositoryTest#spaceRunningOutDuringTheCopyNeedsTheWholeFile
    @Test func spaceRunningOutDuringTheCopyNeedsTheWholeFile() async throws {
        // Enough space before the copy; somebody else uses it while the copy runs.
        let h = try ImportHarness()
        let url = try long(h)
        let size = Int64(try Data(contentsOf: url).count)
        let storage = ScriptedStorage { $0 == 0 ? .max : Limits.minFreeImportBytes - 1 }

        let outcome = try await h.run(url, h.importer(storage: storage))

        // The copied part is deleted, so a retry needs the whole file plus the margin.
        #expect(outcome == .rejected(.noSpace(bytesNeeded: size + Limits.minFreeImportBytes)))
        #expect(h.noteDirs().isEmpty)
    }

    // ports: ImportRepositoryTest#aStorageErrorAfterTheCopyIsAnOutcomeAndLeavesNothingBehind
    @Test func aStorageErrorAfterTheCopyIsAnOutcomeAndLeavesNothingBehind() async throws {
        let h = try ImportHarness()
        h.audio.failInspections(with: POSIXError(.EIO))

        let outcome = try await h.run(try h.input(ImportFixtures.mp3, "podcast.mp3"))

        #expect(outcome == .rejected(.cannotSave))
        #expect(h.noteDirs().isEmpty)
        #expect(await h.store.all().isEmpty)
    }

    // ports: ImportRepositoryTest#aCancelledImportLeavesNothingBehind
    @Test func aCancelledImportLeavesNothingBehind() async throws {
        let h = try ImportHarness()
        let url = try h.input(ImportFixtures.mp3, "podcast.mp3")
        let service = h.importer()
        let task = Mutex<Task<ImportOutcome, any Error>?>(nil)
        // The cancel arrives while the file is classified, so the import stops just after the move to source.mp3.
        h.audio.onInspect { task.withLock { $0?.cancel() } }
        // The import waits until its handle is stored, so the cancel always finds it.
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let running = Task {
            for await _ in gate { break }
            return try await h.run(url, service)
        }
        task.withLock { $0 = running }
        open.yield()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(h.noteDirs().isEmpty)
        #expect(await h.store.all().isEmpty)
    }

    // ports: ImportRepositoryTest#aTitleTagInPlainOpusDoesNotNameTheNote
    @Test func aTitleTagInPlainOpusDoesNotNameTheNote() async throws {
        // One source decides: the display name. An export writes the note title into the TITLE tag.
        let h = try ImportHarness()
        let id = try h.created(try await h.run(try h.input(try ImportFixtures.opus(comments: ["TITLE=Altro titolo"]), "registrazione.opus")))
        try await h.assertPlain(id, file: ImportService.playbackFilename, duration: 15.84, title: "registrazione")
    }

    @Test func anOggOpusFileWhoseTagsDoNotParseIsRejectedAsOpen() async throws {
        // No CASSINI_FORMAT can be found in comments that do not parse: Android's isCassini gives null, so OPEN.
        let h = try ImportHarness()
        let broken = Array("OpusTags".utf8) + [0xFF, 0xFF, 0xFF, 0x7F]
        let head = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let stream = OggOpus.Stream(head: head, tags: broken, audio: Array(repeating: [0xF8, 0xFF, 0xFE], count: 100),
                                    finalGranule: 96_000, validFraming: true)
        let url = try h.input(try OggOpus.mux(stream, tags: broken), "rotto.opus")

        #expect(try await h.run(url) == .rejected(.cannotOpen))
        #expect(h.noteDirs().isEmpty)
    }

    @Test func aReportedSizeOverTheCapIsRejectedBeforeCoordinating() async throws {
        // Only the size asked before coordination is over the cap: a placeholder would not be downloaded.
        let h = try ImportHarness()
        let asked = Atomic(0)
        let service = h.importer(sizeOf: { _ in asked.add(1, ordering: .relaxed).oldValue == 0 ? Limits.maxImportBytes + 1 : nil })

        let outcome = try await h.run(try h.input(ImportFixtures.m4a, "cloud.m4a"), service)

        #expect(outcome == .rejected(.tooLarge))
        #expect(asked.load(ordering: .relaxed) == 1)
        #expect(h.noteDirs().isEmpty)
    }

    @Test func aReportedSizeWithoutTheSpaceIsRejectedBeforeCoordinating() async throws {
        let h = try ImportHarness()
        let asked = Atomic(0)
        let size = Limits.maxImportBytes - 1
        let service = h.importer(storage: ScriptedStorage(always: size), sizeOf: { _ in
            asked.add(1, ordering: .relaxed).oldValue == 0 ? size : nil
        })

        let outcome = try await h.run(try h.input(ImportFixtures.m4a, "cloud.m4a"), service)

        #expect(outcome == .rejected(.noSpace(bytesNeeded: size + Limits.minFreeImportBytes)))
        #expect(asked.load(ordering: .relaxed) == 1)
    }

    @Test func aDecodeThatFailsOnAFullDiskIsNoSpaceNotAnUnplayableNote() async throws {
        // AVFoundation reports a full disk as an OSStatus, not a POSIX or Cocoa error.
        let h = try ImportHarness()
        h.audio.failDecodes(with: NSError(domain: NSOSStatusErrorDomain, code: -34))
        let storage = ScriptedStorage { $0 == 0 ? 64 << 30 : Limits.minFreeImportBytes - 1 }
        let plain = try h.input(try ImportFixtures.opus(), "pieno.opus")
        let document = try h.input(try ImportFixtures.document("disco pieno", title: "Pieno"), "documento.opus")

        let plainOutcome = try await h.run(plain, h.importer(storage: storage))
        let documentOutcome = try await h.run(document, h.importer(storage: ScriptedStorage { $0 == 0 ? 64 << 30 : 0 }))

        #expect(plainOutcome.failure.map { if case .noSpace = $0 { true } else { false } } == true)
        #expect(documentOutcome.failure.map { if case .noSpace = $0 { true } else { false } } == true)
        #expect(h.noteDirs().isEmpty)
    }

    @Test func aCancelWhileAVFoundationReadsTheFileIsACancellationNotARejection() async throws {
        let h = try ImportHarness()
        let url = try h.input(ImportFixtures.m4a, "memo.m4a")
        let service = h.importer()
        let task = Mutex<Task<ImportOutcome, any Error>?>(nil)
        h.audio.onInspect { task.withLock { $0?.cancel() } }
        let (gate, open) = AsyncStream.makeStream(of: Void.self)
        let running = Task {
            for await _ in gate { break }
            return try await h.run(url, service)
        }
        task.withLock { $0 = running }
        open.yield()

        await #expect(throws: CancellationError.self) { try await running.value }
        #expect(h.noteDirs().isEmpty)
    }

    @Test func exportingAStaleDocumentKeepsItsOtherReadableVariants() async throws {
        let h = try ImportHarness()
        let first = try ImportFixtures.document("prima versione", title: "Due")
        let words = [Word("S1", 0, 400, "seconda"), Word("S1", 500, 900, "versione")]
        let two = try CassiniDocument.create(first, transcript: Transcript(words, language: "it"), title: "Due",
                                             processing: JSONObject(), existing: CassiniDocument.read(first))
        let stale = try OggOpus.mux(OggOpus.read(ImportFixtures.opus(packets: 100)), tags: OggOpus.read(two).tags)
        let id = try h.created(try await h.run(try h.input(stale, "due.opus")))
        let note = try await h.note(id)
        #expect(note.document?.state == .staleAudio)
        #expect(note.versions?.count == 2)
        let folder = h.inputs.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let output = try await PortableExportService(audio: h.audio, provenance: FakeProvenance())
            .export(note, original: h.store.originalAudioURL(for: note), playable: h.store.audioURL(for: note),
                    into: folder, filename: "Due")

        let exported = CassiniDocument.read(output)
        #expect(exported.state == .ok)
        let texts = Set(exported.variants.compactMap { $0.transcript?.words.map(\.text).joined(separator: " ") })
        #expect(texts == ["prima versione", "seconda versione"])
        #expect(exported.selected()?.transcript?.words.map(\.text).joined(separator: " ") == note.text)
    }
}
