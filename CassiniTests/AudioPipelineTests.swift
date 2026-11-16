import XCTest
import AVFoundation
import CassiniNotebook
import CassiniAudio
import CassiniCore
import CassiniEngine
import CassiniEngineTesting
@testable import Cassini

final class AudioPipelineTests: XCTestCase {
    @MainActor func testNativeFLACImportPlaybackAndPortableDecodeAtBothRates() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        for rate in [48_000, 44_100] {
            let test = TestGraph(); defer { test.tearDown() }
            let source = sources.appendingPathComponent("Signal.flac")
            try FLACFixtures.native(rate: rate).write(to: source)
            await test.graph.start()
            test.graph.settings.autoTranscribe = false
            let outcome = await test.graph.imports.importFile(source, opensNote: false).value
            let note = try XCTUnwrap(test.graph.library.notes.first)
            XCTAssertEqual(outcome, .created(note.id))
            XCTAssertEqual(note.audioFilename, "source.flac")
            XCTAssertEqual(note.duration, Double(FLACFixtures.samples) / Double(rate), accuracy: 0.0001)
            await test.graph.playback.show(note, owner: PlaybackOwner())
            XCTAssertEqual(test.playback.loadedURL, test.graph.library.audioURL(note))
            let player = try AVAudioPlayer(contentsOf: source)
            XCTAssertTrue(player.prepareToPlay())
            XCTAssertEqual(player.duration, note.duration, accuracy: 0.001)
            await test.graph.library.commit(note.id) { note in
                note.transcript = [.init(text: "Generated signal", start: 0, end: note.duration)]
                note.status = .ready
            }
            let encoded = try await test.graph.exports.exportPortable(note.id)
            defer { try? FileManager.default.removeItem(at: encoded.deletingLastPathComponent()) }
            XCTAssertEqual(CassiniDocument.read(encoded).state, .ok)
            let decoded = sources.appendingPathComponent("decoded.caf")
            try OpusAudio.decode(encoded, to: decoded)
            let decodedSummary = try await AudioInspection.inspect(decoded)
            XCTAssertEqual(decodedSummary.duration, note.duration, accuracy: 0.001)
            XCTAssertTrue(test.graph.imports.tracker.cards.isEmpty)
        }
    }

    @MainActor func testDamagedFLACShowsNeedsAttentionAndCleansNoteDirectory() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        await test.graph.start()
        for bytes in FLACFixtures.invalid {
            let source = sources.appendingPathComponent("Broken.flac")
            try bytes.write(to: source)
            let outcome = await test.graph.imports.importFile(source, opensNote: false).value
            XCTAssertEqual(outcome, .rejected(.cannotOpen))
            XCTAssertEqual(test.graph.imports.tracker.cards.last?.failure, .cannotOpen)
            XCTAssertEqual(StatusBadgeCopy.template("states.badge.needsAttention", language: "en"), "Needs attention")
            XCTAssertTrue(test.graph.library.notes.isEmpty)
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: test.root.path).filter { UUID(uuidString: $0) != nil }, [])
            let encoded = sources.appendingPathComponent("must-not-seal.opus")
            XCTAssertThrowsError(try OpusAudio.encode(source, to: encoded))
            XCTAssertFalse(FileManager.default.fileExists(atPath: encoded.path))
        }
    }

    @MainActor func testExtensionlessNativeFLACImportsWithPlayableDuration() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        let source = sources.appendingPathComponent("Shared recording")
        try FLACFixtures.native().write(to: source)
        await test.graph.start()
        test.graph.settings.autoTranscribe = false
        let outcome = await test.graph.imports.importFile(source, opensNote: false).value
        let note = try XCTUnwrap(test.graph.library.notes.first)
        XCTAssertEqual(outcome, .created(note.id))
        XCTAssertEqual(note.audioFilename, "source.flac")
        XCTAssertEqual(note.duration, Double(FLACFixtures.samples) / 48_000, accuracy: 0.0001)
        let audio = try XCTUnwrap(test.graph.library.audioURL(note))
        let player = try AVAudioPlayer(contentsOf: audio)
        XCTAssertTrue(player.prepareToPlay())
        XCTAssertEqual(player.duration, note.duration, accuracy: 0.001)
        XCTAssertTrue(test.graph.imports.tracker.cards.isEmpty)
    }

    @MainActor func testDamagedExtensionlessFLACFailsWithoutNoteOrStaging() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        let source = sources.appendingPathComponent("Broken recording")
        let bytes = FLACFixtures.native().dropLast()
        try bytes.write(to: source)
        await test.graph.start()
        let outcome = await test.graph.imports.importFile(source, opensNote: false).value
        XCTAssertEqual(outcome, .rejected(.cannotOpen))
        XCTAssertEqual(test.graph.imports.tracker.cards.last?.failure, .cannotOpen)
        XCTAssertEqual(StatusBadgeCopy.template("states.badge.needsAttention", language: "en"), "Needs attention")
        XCTAssertTrue(test.graph.library.notes.isEmpty)
        let files = try XCTUnwrap(FileManager.default.enumerator(at: test.root, includingPropertiesForKeys: nil))
            .allObjects.compactMap { $0 as? URL }
        XCTAssertFalse(files.contains { $0.lastPathComponent == ImportService.stagingFilename || $0.lastPathComponent == "source.flac" })
        XCTAssertFalse(files.contains { UUID(uuidString: $0.lastPathComponent) != nil })
        XCTAssertEqual(try Data(contentsOf: source), bytes)
    }

    private func makeRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func writeSignal(to url: URL, frequency: Double = 440) throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for index in 0..<48_000 { buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * frequency / 48_000)) * 0.2 }
        try file.write(from: buffer); try file.write(from: buffer)
    }

    func testCAFInspectionAndM4ACompressionPreserveAudio() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("capture.caf")
        let output = root.appendingPathComponent("audio.m4a")
        try writeSignal(to: source)
        let before = try await AudioInspection.inspect(source)
        XCTAssertEqual(before.duration, 2, accuracy: 0.001)
        XCTAssertEqual(before.waveform.count, 96)
        XCTAssertTrue(before.waveform.allSatisfy { $0 > 0.1 && $0 <= 1 })
        try await AudioArchive.compress(source: source, destination: output)
        let after = try await AudioInspection.inspect(output)
        XCTAssertEqual(after.duration, 2, accuracy: 0.1)
        XCTAssertTrue(after.waveform.allSatisfy { $0 > 0.1 })
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    /// A generated 440 Hz tone, 24 kHz mono / 24 kbps Layer III; no external encoder is needed at test time.
    @MainActor func testNativeMP3ImportDecodesAndNeverChangesCallerBytes() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        let source = sources.appendingPathComponent("Tone.mp3")
        let bytes = try XCTUnwrap(Data(base64Encoded: "SUQzBAAAAAAAIlRTU0UAAAAOAAADTGF2ZjYzLjEuMTAyAAAAAAAAAAAAAAD/8zTEAAzoRpxfTBgCBuWyQABevXnZmZvwCQBMAMCYHxHJ5/cHAQBAMYnPh/EAIZcH34IHC4Y1Amfwfd0+7p93Skbiz26n3TD/8zTEBw3wtoQBm1AAtSO2KhgtPDBgaVHfFZkoYW2e3r58AlAZAo/isIoRRD/j0enEw++VBURHvrBURHv4lnCfqHwIAOWtAQD/8zTECg9AWiwB3gAAaYHoWRhUD5GCcGiYSoiR5OvcGe8IeYUoVRgqgnGC2BMYAAB5ZEvStJxpFj/////////pDccbGBukht3/8zTECA6wUix057JAhTMEAQwyQTi+5CEiYIIjZ1SbamL6EifkBlil4FTs4cuNyw/jatdGmz+++706dFn/6uiivRdxFNy4hgn/8zTECA6IWhwA7/RAgSYlCYcqOAZmiYQhNxliLdMYMECkGz0mCVBciKAk01yO5A853X/9Fnu9VWj2f39dVPXVnpM87NEgxYL/8zTECA44WhwA7/RAQHE+c9hoZ3D6YEIFRmBvujJgGALGY/sYBqFSwoFT+aXA8HUfP///dr+nRZt93XdX0qWekMDMlDAEYkD/8zTECgyYWigA5/RA6eMqJpsvGBIg2Bj7yUYYJKBuG4imPMAAOgmZTHp2es9////////9XRUSSByR0AeylApSONzoMUBMFBD/8zTEEgygSlR+RroiTuPlzFgFQgAmIu9LbXEXrV6Pb/ufctdWvTY1v2ddf16FFottleAGOVWtHWZCgqaJ7mMiRgfgqGwggAb/8zTEGgygSkR+37BAGqA8B8l+lqutIbYmv3f7ez77v+n2f/r+ha1DBjY07CEESAajCOvDDARTAvgE80FUH9MJgAFwHyDKosf/8zTEIgxgUigA7/RAkSVxupEKE9///7v////+heABb+5Dk2juYKg+YIj+YgjiZgFAerO+Z9lOYlgas8twryxT5iD//UpMkDj/8zTEKwnYTlgZXQAAF03G4vG4GEpYeCAqGGvCgc57IEiAIN1o0gYs2GCYM/ydFzlcATEIAuqSeJ3MicMA5INuEtFbeXGJxZv/8zTEPhhRVqJZmoAAj5HCOSOEfX006amLpSKxNE8Uf0Gst00jE8Ympk7+WB4ClQRqTEFNRTQuMKqqqqqqqqqqqqqqqqqqqqr/8zTEFwAAA0gBwAAAqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqo="))
        try bytes.write(to: source)
        await test.graph.start()
        test.graph.settings.autoTranscribe = false
        let outcome = await test.graph.imports.importFile(source, opensNote: false).value
        let note = try XCTUnwrap(test.graph.library.notes.first)
        XCTAssertEqual(outcome, .created(note.id))
        XCTAssertEqual(note.audioFilename, "source.mp3")
        XCTAssertGreaterThan(note.duration, 0.1)
        XCTAssertEqual(note.waveform.count, 96)
        XCTAssertEqual(try Data(contentsOf: source), bytes)
        XCTAssertTrue(test.graph.imports.tracker.cards.isEmpty)
    }

    func testInvalidAudioIsRejected() async throws {
        let root = try makeRoot(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invalid.wav")
        try Data("not audio".utf8).write(to: url)
        do { _ = try await AudioInspection.inspect(url); XCTFail("Invalid audio must not be accepted") }
        catch { XCTAssertTrue(FileManager.default.fileExists(atPath: url.path)) }
    }

    @MainActor func testInterruptedCaptureAndTranscriptionRecovery() async throws {
        let test = TestGraph(); defer { test.tearDown() }
        let repository = try NoteRepository(root: test.root)
        var recording = Note(title: "Interrupted recording", audioFilename: "capture.caf")
        recording.status = .recording; recording.audio = .live
        try repository.save(recording)
        try writeSignal(to: repository.audioURL(for: recording))
        var transcribing = Note(title: "Interrupted transcription")
        transcribing.status = .transcribing
        transcribing.transcript = [.init(text: "Keep this earlier transcript.", start: 0, end: 1)]
        try repository.save(transcribing)
        let store = test.graph.library
        await test.graph.start()
        await store.settle()
        XCTAssertEqual(store.note(recording.id)?.status, .audioOnly)
        XCTAssertEqual(store.note(recording.id)?.audio, .plain)
        XCTAssertEqual(store.note(recording.id)?.duration ?? 0, 2, accuracy: 0.001)
        XCTAssertEqual(store.note(transcribing.id)?.status, .ready)
        XCTAssertEqual(store.note(transcribing.id)?.text, "Keep this earlier transcript.")
        XCTAssertEqual(store.note(transcribing.id)?.failure, .interrupted)
        let saved = try repository.load().notes
        XCTAssertFalse(saved.contains { $0.status == .recording || $0.status == .transcribing })
    }

    @MainActor func testImportCopiesM4AWithoutChangingTheSource() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        let source = sources.appendingPathComponent("Original.caf")
        let compressed = sources.appendingPathComponent("An imported conversation.m4a")
        try writeSignal(to: source)
        try await AudioArchive.compress(source: source, destination: compressed)
        await test.graph.start()
        test.graph.settings.autoTranscribe = false
        let outcome = await test.graph.imports.importFile(compressed, opensNote: true).value
        let store = test.graph.library
        XCTAssertNil(test.graph.imports.tracker.failure)
        XCTAssertEqual(store.notes.count, 1)
        let imported = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(outcome, .created(imported.id))
        XCTAssertEqual(imported.title, "An imported conversation")
        XCTAssertEqual(imported.audioFilename, "source.m4a")
        XCTAssertEqual(imported.origin, .imported)
        XCTAssertEqual(imported.duration, 2, accuracy: 0.1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: compressed.path))
        XCTAssertNotEqual(store.audioURL(imported), compressed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(store.audioURL(imported)).path))
        XCTAssertEqual(test.graph.router.path, [.note(imported.id)])
    }

    @MainActor func testPortableExportReimportPlaysAndPreservesSource() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        let source = sources.appendingPathComponent("capture.wav")
        try writeSignal(to: source)
        await test.graph.start()
        test.graph.settings.autoTranscribe = false
        let store = test.graph.library
        await test.graph.imports.importFile(source, opensNote: false).value
        let id = try XCTUnwrap(store.notes.first?.id)
        await store.commit(id) { note in
            note.transcript = [.init(text: "Hello there", start: 0, end: 1.5, speaker: "Alex", speakerID: "a"),
                               .init(text: "Who is it?", start: 1.5, end: 2)]
            note.speakers = [NoteSpeaker(id: "a", name: "Alex")]; note.status = .ready
        }
        let portable = try await test.graph.exports.exportPortable(id)
        defer { try? FileManager.default.removeItem(at: portable.deletingLastPathComponent()) }
        let sealed = CassiniDocument.read(portable)
        XCTAssertEqual(sealed.state, .ok)
        // The passage without a speaker is written under the label the note shows it with (D47).
        XCTAssertEqual(sealed.speakerLabel("unassigned"), NoteCopy.unknownSpeaker)
        let original = try Data(contentsOf: portable)
        test.clock.advance(by: .seconds(60))
        await test.graph.imports.importFile(portable, opensNote: false).value
        XCTAssertNil(test.graph.imports.tracker.failure)
        let imported = try XCTUnwrap(store.notes.first { $0.origin == .importedDocument })
        XCTAssertNotEqual(imported.id, id)
        XCTAssertEqual(imported.document?.state, .ok)
        XCTAssertEqual(imported.audioFilename, "playback.caf")
        XCTAssertEqual(imported.originalAudioFilename, "document.opus")
        XCTAssertEqual(imported.audio, .plain)
        XCTAssertEqual(imported.transcript.map(\.speaker), ["Alex", NoteCopy.unknownSpeaker])
        XCTAssertEqual(imported.duration, 2, accuracy: 0.01)
        XCTAssertEqual(try Data(contentsOf: XCTUnwrap(store.originalAudioURL(imported))), original)
        XCTAssertEqual(try Data(contentsOf: portable), original)
        await test.graph.playback.show(imported, owner: PlaybackOwner())
        XCTAssertEqual(test.graph.playback.state.noteID, imported.id)
        XCTAssertEqual(test.playback.loadedURL, store.audioURL(imported))
    }

    /// The tests run in English, where the label is the literal "Unknown speaker"; a stand-in label shows that the
    /// export store writes the one it is given (the app's `ExportCopy.texts`, in the user's language) into the sealed
    /// document, as into the transcript exports, rather than a fixed string.
    @MainActor func testTheSealedDocumentLabelsPassagesWithoutASpeakerWithTheExportTexts() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        let source = sources.appendingPathComponent("capture.wav")
        try writeSignal(to: source)
        await test.graph.start()
        test.graph.settings.autoTranscribe = false
        let store = test.graph.library
        await test.graph.imports.importFile(source, opensNote: false).value
        let id = try XCTUnwrap(store.notes.first?.id)
        await store.commit(id) { note in
            note.transcript = [.init(text: "Hello", start: 0, end: 1, speaker: "Alex", speakerID: "a"),
                               .init(text: "Who is it?", start: 1, end: 2)]
            note.speakers = [NoteSpeaker(id: "a", name: "Alex")]; note.status = .ready
        }
        let english = ExportCopy.texts(locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!)
        let texts = ExportTexts(subtitle: english.subtitle, emptyText: english.emptyText, unassignedLabel: "Voce senza nome")
        let exports = ExportStore(library: store, audio: test.graph.environment.audio,
                                  folder: test.root.appendingPathComponent("tmp/StandIn", isDirectory: true), texts: texts) {}

        let portable = try await exports.exportPortable(id)
        let text = try await exports.exportTranscript(id, format: .text)

        XCTAssertEqual(CassiniDocument.read(portable).speakerLabel("unassigned"), "Voce senza nome")
        XCTAssertTrue(try String(contentsOf: text, encoding: .utf8).contains("Voce senza nome"))
    }

    @MainActor func testThreeFilesPickedAtOnceAreAllImportedAndAReimportOpensTheNote() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        var files: [URL] = []
        for (index, name) in ["One.wav", "Two.wav", "Three.wav"].enumerated() {
            let url = sources.appendingPathComponent(name)
            try writeSignal(to: url, frequency: 220 * Double(index + 1))
            files.append(url)
        }
        await test.graph.start()
        test.graph.settings.autoTranscribe = false
        // As the picker does: every import starts before any ends.
        let imports = files.map { test.graph.imports.importFile($0, opensNote: false) }
        XCTAssertEqual(test.graph.imports.tracker.running, ["One.wav", "Two.wav", "Three.wav"])
        var outcomes: [ImportOutcome?] = []
        for running in imports { outcomes.append(await running.value) }
        XCTAssertEqual(outcomes.compactMap { $0?.noteID }.count, 3)
        XCTAssertEqual(Set(test.graph.library.notes.map(\.title)), ["One", "Two", "Three"])
        XCTAssertTrue(test.graph.imports.tracker.running.isEmpty)
        XCTAssertEqual(test.graph.router.path, [])

        let again = await test.graph.imports.importFile(files[1], opensNote: true).value
        let existing = try XCTUnwrap(test.graph.library.notes.first { $0.title == "Two" })
        XCTAssertEqual(again, .existing(existing.id))
        XCTAssertEqual(test.graph.library.notes.count, 3)
        XCTAssertEqual(test.graph.router.path, [.note(existing.id)])
    }

    @MainActor func testAFileThatIsNotAudioShowsTheImportErrorAndAddsNothing() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let test = TestGraph(); defer { test.tearDown() }
        let url = sources.appendingPathComponent("notes.m4a")
        try Data("not audio at all".utf8).write(to: url)
        await test.graph.start()
        let outcome = await test.graph.imports.importFile(url, opensNote: true).value
        XCTAssertEqual(outcome, .rejected(.cannotOpen))
        XCTAssertEqual(test.graph.imports.tracker.failure?.kind, .cannotOpen)
        XCTAssertEqual(test.graph.imports.tracker.failure?.displayName, "notes.m4a")
        XCTAssertTrue(test.graph.library.notes.isEmpty)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: test.root.path).filter { UUID(uuidString: $0) != nil }, [])
    }

    @MainActor func testAFileOpenedDuringLaunchWaitsForTheLibraryAndOpensTheNoteItAlreadyHas() async throws {
        let sources = try makeRoot(); defer { try? FileManager.default.removeItem(at: sources) }
        let first = TestGraph(); defer { first.tearDown() }
        let url = sources.appendingPathComponent("Meeting.wav")
        try writeSignal(to: url)
        await first.graph.start()
        first.graph.settings.autoTranscribe = false
        let firstOutcome = await first.graph.imports.importFile(url, opensNote: false).value
        let created = try XCTUnwrap(firstOutcome?.noteID)
        await first.graph.library.settle()

        // A cold launch from Files: the open arrives before the launch work has read the notes.
        let relaunch = first.reopened()
        let opening = relaunch.graph.imports.importFile(url, opensNote: true)
        XCTAssertEqual(relaunch.graph.imports.tracker.running, ["Meeting.wav"])
        await relaunch.graph.start()
        let outcome = await opening.value

        XCTAssertEqual(outcome, .existing(created))
        XCTAssertEqual(relaunch.graph.library.notes.map(\.id), [created])
        XCTAssertEqual(relaunch.graph.router.path, [.note(created)])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: relaunch.root.path).filter { UUID(uuidString: $0) != nil },
                       [created.uuidString])
    }
}
