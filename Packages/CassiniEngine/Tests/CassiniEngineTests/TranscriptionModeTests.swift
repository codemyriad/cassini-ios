import Foundation
import Synchronization
import Testing
import CassiniNotebook
@testable import CassiniEngine

@MainActor @Suite struct TranscriptionModeTests {
    final class SpyPrecomputer: RecordingPrecomputing, @unchecked Sendable {
        struct State: Sendable {
            var started: [(UUID, URL)] = []
            var stopped: [UUID] = []
            var preempts = 0
            var checkpointNotes: Set<UUID> = []
        }
        let state = Mutex(State())

        func start(noteID: UUID, captureURL: URL) {
            state.withLock { $0.started.append((noteID, captureURL)) }
        }
        func stop(noteID: UUID) async {
            state.withLock { $0.stopped.append(noteID) }
        }
        func preempt() async {
            state.withLock { $0.preempts += 1 }
        }
        func hasPrecomputeCheckpoint(for noteID: UUID) -> Bool {
            state.withLock { $0.checkpointNotes.contains(noteID) }
        }
    }

    @Test func settingsStoreDefaultsToAfterStopAndNormalizesPersistedModes() {
        let suite = "cassini.mode-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        let clock = RecordingTestClock(now: Date(timeIntervalSince1970: 1_700_000_000))
        let fresh = SettingsStore(defaults: defaults, clock: clock)
        #expect(fresh.transcriptionMode == .afterStop)
        #expect(fresh.currentTranscriptionMode == .afterStop)

        fresh.transcriptionMode = .recordOnly
        #expect(defaults.string(forKey: SettingsKeys.transcriptionMode) == "recordOnly")
        #expect(fresh.currentTranscriptionMode == .recordOnly)

        // Python & Kotlin aliases resolve cleanly.
        defaults.set("transcribe_while_recording", forKey: SettingsKeys.transcriptionMode)
        let fromSnake = SettingsStore(defaults: defaults, clock: clock)
        #expect(fromSnake.transcriptionMode == .transcribeWhileRecording)

        defaults.set("RECORD_ONLY", forKey: SettingsKeys.transcriptionMode)
        let fromScreaming = SettingsStore(defaults: defaults, clock: clock)
        #expect(fromScreaming.transcriptionMode == .recordOnly)

        // Unknown, empty, wrong-case, and non-string values fall back deterministically to `.afterStop`.
        for invalid: Any in ["livePreview", "", "recordonly", 42] {
            defaults.set(invalid, forKey: SettingsKeys.transcriptionMode)
            let loaded = SettingsStore(defaults: defaults, clock: clock)
            #expect(loaded.transcriptionMode == .afterStop)
        }
    }

    @Test func recordOnlyStartsZeroPrecomputeAndDoesNotAutoEnqueueOnStop() async throws {
        let spy = SpyPrecomputer()
        let h = try RecordingHarness()
        defer { h.tearDown() }
        h.settings.transcriptionMode = .recordOnly
        let controller = RecordingController(parts: .init(
            ready: {}, notes: h.notes, capture: h.capture, storage: h.storage, audio: h.audio,
            settings: h.settings, handoff: h.handoff, clock: h.clock, defaultTitle: { _ in "Voice note" },
            precompute: spy
        ))

        #expect(controller.start())
        await controller.operations?.value
        let id = try #require(controller.state.activeRecording?.noteID)
        h.capture.elapsed = 12
        controller.finish()
        await controller.settle()

        #expect(spy.state.withLock { $0.started }.isEmpty, "recordOnly must never start precompute during recording")
        #expect(h.handoff.handedOff.isEmpty, "recordOnly must not auto-enqueue transcription on Stop")
        let note = try #require(await h.note(id))
        #expect(note.status == .audioOnly)
        #expect(note.audioFilename == "audio.m4a")
    }

    @Test func afterStopStartsZeroPrecomputeAndPreservesShippedStopBehaviour() async throws {
        let spy = SpyPrecomputer()
        let h = try RecordingHarness()
        defer { h.tearDown() }
        h.settings.transcriptionMode = .afterStop
        let controller = RecordingController(parts: .init(
            ready: {}, notes: h.notes, capture: h.capture, storage: h.storage, audio: h.audio,
            settings: h.settings, handoff: h.handoff, clock: h.clock, defaultTitle: { _ in "Voice note" },
            precompute: spy
        ))

        #expect(controller.start())
        await controller.operations?.value
        let id = try #require(controller.state.activeRecording?.noteID)
        h.capture.elapsed = 12
        controller.finish()
        await controller.settle()

        #expect(spy.state.withLock { $0.started }.isEmpty, "afterStop must never start precompute during recording")
        #expect(h.handoff.handedOff == [id])
        let note = try #require(await h.note(id))
        #expect(note.audioFilename == "audio.m4a")
    }

    @Test func transcribeWhileRecordingStartsYieldsOnPauseBackgroundAndPreservesCAFWhenCheckpointed() async throws {
        let spy = SpyPrecomputer()
        let h = try RecordingHarness()
        defer { h.tearDown() }
        h.settings.transcriptionMode = .transcribeWhileRecording
        let controller = RecordingController(parts: .init(
            ready: {}, notes: h.notes, capture: h.capture, storage: h.storage, audio: h.audio,
            settings: h.settings, handoff: h.handoff, clock: h.clock, defaultTitle: { _ in "Voice note" },
            precompute: spy
        ))

        #expect(controller.start())
        await controller.operations?.value
        let id = try #require(controller.state.activeRecording?.noteID)
        #expect(spy.state.withLock { $0.started.map(\.0) } == [id])

        // Pause yields immediately; resume restarts follower.
        controller.pause()
        controller.resume()
        // Backgrounding yields immediately; returning restarts follower.
        controller.isAppActive = false
        controller.isAppActive = true

        // Mark a precompute checkpoint as present so Stop preserves capture.caf for prefix-verified resume.
        spy.state.withLock { _ = $0.checkpointNotes.insert(id) }
        h.capture.elapsed = 30
        controller.finish()
        await controller.settle()

        #expect(spy.state.withLock { $0.stopped } == [id])
        #expect(spy.state.withLock { $0.preempts } >= 2)
        #expect(h.handoff.handedOff == [id])
        let note = try #require(await h.note(id))
        #expect(note.audioFilename == "capture.caf", "capture.caf must stay intact for prefix-verified resume")
    }

    @Test func noteWorkFoldersRecognizesValidPrefixAndTreatsStalePrecomputeAsMissing() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = try NoteStore(root: root)
        let note = Note(title: "Live", audioFilename: "capture.caf")
        try await store.save(note)
        let audioURL = store.audioURL(for: note)

        // Write a 2-second 48 kHz mono PCM16LE CAF file.
        let frames = 96_000
        var pcm = Data(capacity: frames * 2)
        for i in 0..<frames {
            var s = Int16((i % 100) - 50).littleEndian
            withUnsafeBytes(of: &s) { pcm.append(contentsOf: $0) }
        }
        try Self.writeCAF(to: audioURL, sampleRate: 48_000, pcm: pcm, declaredSize: Int64(pcm.count + 4))

        let committed: UInt64 = 48_048
        let reader = try LiveCAFReader(url: audioURL)
        let sha = try reader.prefixSHA256(committedFrames: committed)
        reader.close()

        let work = NoteWorkFolders(notes: store)
        let validCP = CheckpointState(
            source: "capture.caf",
            signature: "old:0",
            model: "parakeet-model",
            segments: [],
            doneMs: 1_000,
            totalMs: 0,
            elapsedMs: 25,
            origin: .precompute,
            recognitionSampleCount: 16_000,
            committedPrefix: CommittedPrefix(
                kind: .cafPcm16LeFrames,
                sourceSampleRateHz: 48_000,
                committedUnitCount: committed,
                prefixSha256: sha
            )
        )
        try work.files.save(validCP, for: note.id)
        let statusValid = await work.status(of: note.id)
        #expect(statusValid == .saved(doneMs: 1_000, totalMs: 0, words: 0))

        // Corrupt prefix byte -> precompute checkpoint reports `.missing` (never `.mismatch`).
        var corrupted = pcm
        corrupted[10] ^= 0xFF
        try Self.writeCAF(to: audioURL, sampleRate: 48_000, pcm: corrupted, declaredSize: Int64(corrupted.count + 4))
        let statusStale = await work.status(of: note.id)
        #expect(statusStale == .missing)
    }

    private static func writeCAF(to url: URL, sampleRate: Double, pcm: Data, declaredSize: Int64) throws {
        var out = Data()
        out.append(contentsOf: "caff".utf8)
        out.append(contentsOf: [0, 1, 0, 0])
        out.append(contentsOf: "desc".utf8)
        appendBE(&out, Int64(32))
        appendBE(&out, sampleRate.bitPattern)
        out.append(contentsOf: "lpcm".utf8)
        appendBE(&out, UInt32(2))
        appendBE(&out, UInt32(2))
        appendBE(&out, UInt32(1))
        appendBE(&out, UInt32(1))
        appendBE(&out, UInt32(16))
        out.append(contentsOf: "data".utf8)
        appendBE(&out, declaredSize)
        appendBE(&out, UInt32(0))
        out.append(pcm)
        try out.write(to: url)
    }

    private static func appendBE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
}
