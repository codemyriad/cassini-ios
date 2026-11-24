import AVFoundation
import CassiniCore
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook
import CassiniWhistle
import Foundation
import Synchronization
import Testing
@testable import CassiniInference

/// End-to-end verification of `D-1123`:
/// - `LiveCAFReader` + `AVAudioConverter` matches `FileReader` bit-for-bit on 48 kHz mono PCM16LE `.caf`.
/// - Paired `afterStop` vs `transcribeWhileRecording` equivalence for Parakeet (+ streaming Sortformer + voice clips
///   + CAM++ voiceprint matching) and Whistle (97-tap FIR + `WhistleSpeechGate` + `WhistlePipelineState`).
/// - Negative controls: simulated `CAFRepair` truncation/alteration inside the prefix, thermal `.serious`, low memory,
///   backgrounding, `NativeBudget` preemption, and zero native model allocation in `recordOnly` / `afterStop`.
@Suite(.serialized) struct HeadStartPrecomputeTests {
    // MARK: - CAF synthesis helpers

    /// Generates 48 kHz mono PCM16LE bytes with a 1 kHz burst in each second N so both Parakeet and Whistle
    /// test recognizers produce deterministic per-second words after 48 kHz -> 16 kHz resampling.
    private static func make48kPCM16LE(seconds: Int) -> Data {
        let rate = 48_000
        let totalFrames = seconds * rate
        var data = Data(capacity: totalFrames * 2)
        for sec in 0..<seconds {
            let amp = Double(min(sec + 5, 50)) / 100.0 * 0.5
            for f in 0..<rate {
                // Speech burst in [0.25 s ..< 0.55 s) of each second, silence around it.
                let sampleDouble: Double
                if f >= rate / 4 && f < rate * 11 / 20 {
                    let phase = 2.0 * Double.pi * 1_000.0 * Double(f) / Double(rate)
                    sampleDouble = sin(phase) * amp
                } else {
                    sampleDouble = 0
                }
                var i16 = Int16(max(-32768, min(32767, Int((sampleDouble * 32768.0).rounded())))).littleEndian
                withUnsafeBytes(of: &i16) { data.append(contentsOf: $0) }
            }
        }
        return data
    }

    private static func writeCAF(to url: URL, sampleRate: Double = 48_000, pcm: Data, finalized: Bool) throws {
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
        appendBE(&out, finalized ? Int64(pcm.count + 4) : Int64(-1))
        appendBE(&out, UInt32(0))
        out.append(pcm)
        try out.write(to: url)
    }

    private static func appendBE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func installSparseModel(_ model: ModelDescriptor, in root: URL) throws {
        let dir = model.directory(in: root)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for artifact in model.artifacts {
            let url = dir.appendingPathComponent(artifact.name)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: UInt64(artifact.size))
            try handle.close()
        }
        try Data("notices".utf8).write(to: dir.appendingPathComponent(ModelDescriptor.noticeFile))
    }

    // MARK: - 1. LiveCAFReader + AVAudioConverter matches FileReader bit-for-bit

    @Test func liveCAFReaderConverterMatchesFileReaderBitForBit() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("capture.caf")
        let pcm = Self.make48kPCM16LE(seconds: 5)
        try Self.writeCAF(to: url, pcm: pcm, finalized: true)

        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let fileReader = try FileReader(url: url, from: 0, to: outputFormat, downmix: true)
        var fileSamples: [Float] = []
        while let (buf, _) = fileReader.nextBuffer() {
            let count = Int(buf.frameLength)
            fileSamples.append(contentsOf: UnsafeBufferPointer(start: buf.floatChannelData![0], count: count))
        }

        let liveReader = try LiveCAFReader(url: url)
        defer { liveReader.close() }
        let sourceFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let converter = try #require(AVAudioConverter(from: sourceFormat, to: outputFormat))
        converter.downmix = true

        var liveSamples: [Float] = []
        for sec in 0..<4 {
            let floats = try liveReader.readFloats(fromFrame: UInt64(sec * 48_000), frameCount: 48_000)
            let block = try #require(AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: 48_000))
            block.frameLength = 48_000
            floats.withUnsafeBufferPointer { block.floatChannelData![0].update(from: $0.baseAddress!, count: 48_000) }
            let cap = AVAudioFrameCount((48_000.0 * (16_000.0 / 48_000.0)).rounded(.up)) + 32
            let out = try #require(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: cap))
            var consumed = false
            var err: NSError?
            let status = converter.convert(to: out, error: &err) { _, st in
                if consumed { st.pointee = .noDataNow; return nil }
                consumed = true
                st.pointee = .haveData
                return block
            }
            #expect(status != .error && err == nil)
            liveSamples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
        }

        #expect(liveSamples.count > 0)
        #expect(liveSamples == Array(fileSamples.prefix(liveSamples.count)),
                "LiveCAFReader + AVAudioConverter must match FileReader bit-for-bit over committed blocks")
    }

    // MARK: - 2. Paired afterStop vs transcribeWhileRecording (Parakeet + Sortformer + CAM++)

    @Test func pairedAfterStopVsTranscribeWhileRecordingParakeetWithSpeakersAndVoiceprints() async throws {
        let fullPCM = Self.make48kPCM16LE(seconds: 65)
        let prefixPCM = fullPCM.prefix(35 * 48_000 * 2) // 35 s recorded so far (> 28 s first window)

        let baseline = try await runParakeetLane(fullPCM: fullPCM, growingPrefixPCM: nil)
        let headStart = try await runParakeetLane(fullPCM: fullPCM, growingPrefixPCM: prefixPCM)

        #expect(headStart.precomputeCheckpointsSaved >= 1, "transcribeWhileRecording must write a precompute checkpoint")
        #expect(headStart.postStopDecodeCalls < baseline.postStopDecodeCalls,
                "post-Stop Parakeet must skip already-precomputed windows")

        // Assert identical final words, timestamps, speaker turns (normalized slot order), voiceprint matches, and provenance.
        let baseWords = baseline.note.transcript.flatMap(\.draftWords)
        let headWords = headStart.note.transcript.flatMap(\.draftWords)
        #expect(!baseWords.isEmpty)
        #expect(headWords.map(\.text) == baseWords.map(\.text))
        #expect(headWords.map(\.startMs) == baseWords.map(\.startMs))
        #expect(headWords.map(\.endMs) == baseWords.map(\.endMs))

        // Normalize per-run speaker UUID prefix to slot suffix so speaker assignments match identically.
        let slotOf: (String) -> String = { id in id.split(separator: "_").last.map(String.init) ?? id }
        #expect(headWords.map { slotOf($0.speaker) } == baseWords.map { slotOf($0.speaker) })

        #expect(headStart.appliedPrints.count == baseline.appliedPrints.count)
        #expect(!headStart.appliedPrints.isEmpty)
        for (a, b) in zip(headStart.appliedPrints, baseline.appliedPrints) {
            #expect(a.vector == b.vector)
            #expect(a.speechSeconds == b.speechSeconds)
        }

        let baseProv = try #require(baseline.provenance)
        let headProv = try #require(headStart.provenance)
        #expect(headProv.engine == baseProv.engine)
        #expect(headProv.model == baseProv.model)
        #expect(headProv.segmentation == baseProv.segmentation)
        #expect(headProv.language == baseProv.language)
        #expect(headProv.resumedFromMs == baseProv.resumedFromMs)
        #expect(headProv.speakerDiarization?.speakerCount == baseProv.speakerDiarization?.speakerCount)
        #expect(headProv.speakerDiarization?.turnCount == baseProv.speakerDiarization?.turnCount)
        #expect(headProv.speakerIdentification?.speakersWithPrints == baseProv.speakerIdentification?.speakersWithPrints)
    }

    // MARK: - 3. Paired afterStop vs transcribeWhileRecording (Whistle)

    @Test func pairedAfterStopVsTranscribeWhileRecordingWhistle() async throws {
        let fullPCM = Self.make48kPCM16LE(seconds: 12)
        let prefixPCM = fullPCM.prefix(7 * 48_000 * 2) // 7 s committed during recording

        let baseline = try await runWhistleLane(fullPCM: fullPCM, growingPrefixPCM: nil)
        let headStart = try await runWhistleLane(fullPCM: fullPCM, growingPrefixPCM: prefixPCM)

        #expect(headStart.precomputeCheckpointsSaved >= 1)
        #expect(headStart.postStopEarliestFrameRead > 0, "post-Stop Whistle must seek past precomputed sourceFrame")

        let baseWords = baseline.note.transcript.flatMap(\.draftWords)
        let headWords = headStart.note.transcript.flatMap(\.draftWords)
        #expect(!baseWords.isEmpty)
        #expect(headWords.map(\.text) == baseWords.map(\.text))
        #expect(headWords.map(\.startMs) == baseWords.map(\.startMs))
        #expect(headWords.map(\.endMs) == baseWords.map(\.endMs))
        #expect(headStart.note.language == baseline.note.language)

        let baseProv = try #require(baseline.provenance)
        let headProv = try #require(headStart.provenance)
        #expect(headProv.engine == baseProv.engine)
        #expect(headProv.model == baseProv.model)
        #expect(headProv.segmentation == baseProv.segmentation)
        #expect(headProv.language == baseProv.language)
        #expect(headProv.resumedFromMs == baseProv.resumedFromMs)
    }

    @Test func whistlePrecomputeThrottlesPeriodicDiskWritesToTenSecondsAndFlushesOnExit() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try NoteStore(root: dir.appendingPathComponent("notes", isDirectory: true))
        let checkpoints = CheckpointFiles(notes: store)
        let capability = WhistleCapability(arm64: true, operatingSystemSupported: true, cpuSupported: true,
                                           bundleVerified: true, pipelineAccepted: true, deviceAccepted: true)

        // Case A: 25 s growing CAF (24 full 1 s blocks behind 0.1 s safety margin) ->
        // periodic saves at 10 s and 20 s plus final flush at 24 s (3 writes instead of 24).
        do {
            let note = Note(title: "WhistleThrottle25s", audioFilename: "capture.caf")
            try await store.save(note)
            let cafURL = store.audioURL(for: note)
            try Self.writeCAF(to: cafURL, pcm: Self.make48kPCM16LE(seconds: 25), finalized: false)

            let savedFrames = Mutex<[Int64]>([])
            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: NativeBudget(),
                mode: { .transcribeWhileRecording },
                engine: { .whistle(.init(acceptance: { capability }, backend: Self.deterministicWhistleBackend(), skipBundleVerification: true)) },
                pressure: PrecomputePressure(isAppActive: { true }, thermalState: { .nominal }, availableMemory: { 2 << 30 }),
                safetyMarginFrames: 4_800,
                onCheckpointSaved: { _, cp in
                    if let frame = cp.whistle?.sourceFrame {
                        savedFrames.withLock { $0.append(frame) }
                    }
                }
            )
            await pre.runOnce(noteID: note.id, captureURL: cafURL)

            let actualFrames: [Int64] = savedFrames.withLock { $0 }
            let expectedFrames: [Int64] = [480_000, 960_000, 1_152_000]
            #expect(actualFrames == expectedFrames,
                    "Whistle precompute must persist at 10 s intervals and flush settled tail on exit")
            let loaded = try #require(try checkpoints.load(note.id))
            let expectedFinalFrame: Int64 = 1_152_000
            #expect(loaded.whistle?.sourceFrame == expectedFinalFrame)
        }

        // Case B: 21 s growing CAF (20 full 1 s blocks, exact multiple of 10 s) ->
        // periodic saves at 10 s and 20 s only, no duplicate flush at exit.
        do {
            let note = Note(title: "WhistleThrottle21s", audioFilename: "capture.caf")
            try await store.save(note)
            let cafURL = store.audioURL(for: note)
            try Self.writeCAF(to: cafURL, pcm: Self.make48kPCM16LE(seconds: 21), finalized: false)

            let savedFrames = Mutex<[Int64]>([])
            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: NativeBudget(),
                mode: { .transcribeWhileRecording },
                engine: { .whistle(.init(acceptance: { capability }, backend: Self.deterministicWhistleBackend(), skipBundleVerification: true)) },
                pressure: PrecomputePressure(isAppActive: { true }, thermalState: { .nominal }, availableMemory: { 2 << 30 }),
                safetyMarginFrames: 4_800,
                onCheckpointSaved: { _, cp in
                    if let frame = cp.whistle?.sourceFrame {
                        savedFrames.withLock { $0.append(frame) }
                    }
                }
            )
            await pre.runOnce(noteID: note.id, captureURL: cafURL)

            let actualFrames: [Int64] = savedFrames.withLock { $0 }
            let expectedFrames: [Int64] = [480_000, 960_000]
            #expect(actualFrames == expectedFrames,
                    "Exact 10 s multiple must not double-write on exit")
        }
    }

    @Test func whistlePrecomputeFlushesUncommittedWorkImmediatelyOnYieldAndStop() async throws {
        final class CancellationGate: @unchecked Sendable {
            private let lock = Mutex<(continuation: CheckedContinuation<Void, Never>?, resumed: Bool)>((nil, false))

            func waitUntilCancelled() async {
                await withTaskCancellationHandler {
                    await withCheckedContinuation { cont in
                        let shouldResumeNow = lock.withLock { state -> Bool in
                            if state.resumed { return true }
                            state.continuation = cont
                            return false
                        }
                        if shouldResumeNow { cont.resume() }
                    }
                } onCancel: {
                    let cont = lock.withLock { state -> CheckedContinuation<Void, Never>? in
                        state.resumed = true
                        let pending = state.continuation
                        state.continuation = nil
                        return pending
                    }
                    cont?.resume()
                }
            }
        }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try NoteStore(root: dir.appendingPathComponent("notes", isDirectory: true))
        let checkpoints = CheckpointFiles(notes: store)
        let capability = WhistleCapability(arm64: true, operatingSystemSupported: true, cpuSupported: true,
                                           bundleVerified: true, pipelineAccepted: true, deviceAccepted: true)

        // Part A: Thermal yield (.serious) after 10 s periodic checkpoint + 2 more settled segments ->
        // flushes the intermediate settled state immediately before exiting.
        do {
            let note = Note(title: "WhistleYieldFlush", audioFilename: "capture.caf")
            try await store.save(note)
            let cafURL = store.audioURL(for: note)
            try Self.writeCAF(to: cafURL, pcm: Self.make48kPCM16LE(seconds: 25), finalized: false)

            let savedFrames = Mutex<[Int64]>([])
            let thermal = Mutex(ProcessInfo.ThermalState.nominal)
            let postTenSegments = Mutex(0)
            let baseBackend = Self.deterministicWhistleBackend()
            let backend = WhistleSessionBackend(
                makeVAD: baseBackend.makeVAD,
                prepare: baseBackend.prepare,
                transcribe: { samples, cap, bundle, submitted, resultReady in
                    let res = try await baseBackend.transcribe(samples, cap, bundle, submitted, resultReady)
                    if !savedFrames.withLock({ $0.isEmpty }) {
                        let count = postTenSegments.withLock { $0 += 1; return $0 }
                        if count == 2 {
                            thermal.withLock { $0 = .serious }
                        }
                    }
                    return res
                },
                close: baseBackend.close
            )

            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: NativeBudget(),
                mode: { .transcribeWhileRecording },
                engine: { .whistle(.init(acceptance: { capability }, backend: backend, skipBundleVerification: true)) },
                pressure: PrecomputePressure(
                    isAppActive: { true },
                    thermalState: { thermal.withLock { $0 } },
                    availableMemory: { 2 << 30 }
                ),
                safetyMarginFrames: 4_800,
                onCheckpointSaved: { _, cp in
                    if let frame = cp.whistle?.sourceFrame {
                        savedFrames.withLock { $0.append(frame) }
                    }
                }
            )
            await pre.runOnce(noteID: note.id, captureURL: cafURL)

            let frames: [Int64] = savedFrames.withLock { $0 }
            let tenSecondsFrames: Int64 = 480_000
            let twentySecondsFrames: Int64 = 960_000
            #expect(frames.count == 2, "Expected 10 s periodic checkpoint plus immediate flush on thermal yield")
            #expect(frames.first == tenSecondsFrames)
            let flushedFrame: Int64 = try #require(frames.last)
            #expect(flushedFrame > tenSecondsFrames)
            #expect(flushedFrame < twentySecondsFrames)
            let persistedFrame: Int64? = try checkpoints.load(note.id)?.whistle?.sourceFrame
            #expect(persistedFrame == flushedFrame)
        }

        // Part B: Stop (`precomputer.stop(noteID:)`) in continuous mode after 10 s periodic checkpoint ->
        // flushes settled work even though the follower task is cancelled.
        do {
            let note = Note(title: "WhistleStopFlush", audioFilename: "capture.caf")
            try await store.save(note)
            let cafURL = store.audioURL(for: note)
            try Self.writeCAF(to: cafURL, pcm: Self.make48kPCM16LE(seconds: 25), finalized: false)

            let savedFrames = Mutex<[Int64]>([])
            let (enteredPostTen, enteredPostTenCont) = AsyncStream.makeStream(of: Void.self)
            let pausedOnce = Mutex(false)
            let gate = CancellationGate()
            let baseBackend = Self.deterministicWhistleBackend()
            let backend = WhistleSessionBackend(
                makeVAD: baseBackend.makeVAD,
                prepare: baseBackend.prepare,
                transcribe: { samples, cap, bundle, submitted, resultReady in
                    let res = try await baseBackend.transcribe(samples, cap, bundle, submitted, resultReady)
                    if !savedFrames.withLock({ $0.isEmpty }) {
                        let shouldPause = pausedOnce.withLock { already -> Bool in
                            if already { return false }
                            already = true
                            return true
                        }
                        if shouldPause {
                            enteredPostTenCont.yield()
                            enteredPostTenCont.finish()
                            await gate.waitUntilCancelled()
                        }
                    }
                    return res
                },
                close: baseBackend.close
            )

            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: NativeBudget(),
                mode: { .transcribeWhileRecording },
                engine: { .whistle(.init(acceptance: { capability }, backend: backend, skipBundleVerification: true)) },
                pressure: PrecomputePressure(isAppActive: { true }, thermalState: { .nominal }, availableMemory: { 2 << 30 }),
                safetyMarginFrames: 4_800,
                onCheckpointSaved: { _, cp in
                    if let frame = cp.whistle?.sourceFrame {
                        savedFrames.withLock { $0.append(frame) }
                    }
                }
            )
            pre.start(noteID: note.id, captureURL: cafURL)
            for await _ in enteredPostTen { break }
            await pre.stop(noteID: note.id)

            let frames: [Int64] = savedFrames.withLock { $0 }
            let tenSecondsFrames: Int64 = 480_000
            let twentySecondsFrames: Int64 = 960_000
            #expect(frames.count == 2, "Expected 10 s periodic checkpoint plus immediate flush on Stop")
            #expect(frames.first == tenSecondsFrames)
            let flushedFrame: Int64 = try #require(frames.last)
            #expect(flushedFrame > tenSecondsFrames)
            #expect(flushedFrame < twentySecondsFrames)
            let persistedFrame: Int64? = try checkpoints.load(note.id)?.whistle?.sourceFrame
            #expect(persistedFrame == flushedFrame)
        }
    }

    // MARK: - 4. Negative controls

    @Test func cafRepairTruncationOrAlterationInsidePrefixFallsBackToCleanFullDecode() async throws {
        let fullPCM = Self.make48kPCM16LE(seconds: 12)
        let prefixPCM = fullPCM.prefix(7 * 48_000 * 2)

        // Case A: Simulated CAFRepair truncation inside the committed prefix (final file shorter than committedUnitCount).
        let truncatedPCM = fullPCM.prefix(4 * 48_000 * 2)
        let truncatedRun = try await runWhistleLane(fullPCM: truncatedPCM, growingPrefixPCM: prefixPCM)
        #expect(truncatedRun.precomputeCheckpointsSaved >= 1)
        #expect(truncatedRun.outcome == .done, "Truncation inside prefix must discard precompute and succeed, never CHECKPOINT_MISMATCH")
        #expect(truncatedRun.postStopEarliestFrameRead == 0, "Fallback must decode cleanly from frame 0")

        // Case B: Simulated CAFRepair byte alteration inside the committed prefix.
        var alteredPCM = fullPCM
        alteredPCM[100] ^= 0xFF
        let alteredRun = try await runWhistleLane(fullPCM: alteredPCM, growingPrefixPCM: prefixPCM)
        #expect(alteredRun.precomputeCheckpointsSaved >= 1)
        #expect(alteredRun.outcome == .done, "Alteration inside prefix must discard precompute and succeed, never CHECKPOINT_MISMATCH")
        #expect(alteredRun.postStopEarliestFrameRead == 0, "Fallback must decode cleanly from frame 0")
    }

    @Test func malformedPrecomputeCheckpointsDiscardAndDecodeCleanlyThroughJob() async throws {
        let fullPCM = Self.make48kPCM16LE(seconds: 6)

        // Case A: Unsupported version in precompute checkpoint with no backup -> discard & clean decode.
        let unsupported = try await runWhistleJobWithRawCheckpoint(
            fullPCM: fullPCM,
            mainJSON: #"{"version":99,"origin":"precompute","source":"capture.caf"}"#,
            backupJSON: nil
        )
        #expect(unsupported.outcome == .done)
        #expect(unsupported.earliestFrameRead == 0)
        #expect(!unsupported.note.transcript.isEmpty)

        // Case B: Malformed typed field in precompute checkpoint with corrupt backup -> discard & clean decode.
        let malformed = try await runWhistleJobWithRawCheckpoint(
            fullPCM: fullPCM,
            mainJSON: #"{"version":1,"origin":"precompute","source":"capture.caf","signature":"1:2","model":"m","segments":[],"doneMs":"bad","totalMs":0,"elapsedMs":0,"inferenceMs":0,"resumedFromMs":0,"wordsComplete":false}"#,
            backupJSON: "{corrupt"
        )
        #expect(malformed.outcome == .done)
        #expect(malformed.earliestFrameRead == 0)
        #expect(!malformed.note.transcript.isEmpty)

        // Case C: Non-precompute (batch) unsupported version with no backup -> still fails with CHECKPOINT_MISMATCH.
        let batchMismatch = try await runWhistleJobWithRawCheckpoint(
            fullPCM: fullPCM,
            mainJSON: #"{"version":99,"source":"capture.caf"}"#,
            backupJSON: nil
        )
        #expect(batchMismatch.outcome == .failed(.checkpointMismatch))
    }

    @Test func deletedOrTruncatedClipsSidecarDiscardsPrecomputeAndPreservesVoiceprints() async throws {
        let fullPCM = Self.make48kPCM16LE(seconds: 65)
        let prefixPCM = fullPCM.prefix(35 * 48_000 * 2)

        let baseline = try await runParakeetLane(fullPCM: fullPCM, growingPrefixPCM: nil)
        #expect(!baseline.appliedPrints.isEmpty)

        // Case A: Deleted work/clips.pcm after precompute -> must discard precompute and decode afresh, preserving voiceprints.
        let deleted = try await runParakeetLane(fullPCM: fullPCM, growingPrefixPCM: prefixPCM) { clipsURL in
            try FileManager.default.removeItem(at: clipsURL)
        }
        #expect(deleted.precomputeCheckpointsSaved >= 1)
        #expect(deleted.postStopDecodeCalls == baseline.postStopDecodeCalls,
                "Deleted clips.pcm must discard precompute and run a full decode instead of dropping voice identification")
        #expect(deleted.appliedPrints.count == baseline.appliedPrints.count)
        for (a, b) in zip(deleted.appliedPrints, baseline.appliedPrints) {
            #expect(a.vector == b.vector)
            #expect(a.speechSeconds == b.speechSeconds)
        }

        // Case B: Truncated work/clips.pcm after precompute -> must discard precompute and decode afresh, preserving voiceprints.
        let truncated = try await runParakeetLane(fullPCM: fullPCM, growingPrefixPCM: prefixPCM) { clipsURL in
            try Data(repeating: 0, count: 4).write(to: clipsURL)
        }
        #expect(truncated.precomputeCheckpointsSaved >= 1)
        #expect(truncated.postStopDecodeCalls == baseline.postStopDecodeCalls,
                "Truncated clips.pcm must discard precompute and run a full decode")
        #expect(truncated.appliedPrints.count == baseline.appliedPrints.count)
        for (a, b) in zip(truncated.appliedPrints, baseline.appliedPrints) {
            #expect(a.vector == b.vector)
            #expect(a.speechSeconds == b.speechSeconds)
        }
    }

    @Test func thermalMemoryBackgroundBudgetPreemptionAndNonPrecomputeModesAllocateZeroModels() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modelsRoot = dir.appendingPathComponent("models", isDirectory: true)
        try Self.installSparseModel(ModelCatalog.parakeet, in: modelsRoot)
        let store = try NoteStore(root: dir.appendingPathComponent("notes", isDirectory: true))
        let note = Note(title: "Guard", audioFilename: "capture.caf")
        try await store.save(note)
        let cafURL = store.audioURL(for: note)
        try Self.writeCAF(to: cafURL, pcm: Self.make48kPCM16LE(seconds: 35), finalized: false)

        let checkpoints = CheckpointFiles(notes: store)
        let verifier = ModelVerifier()
        verifier.markVerified(ModelCatalog.parakeet, in: modelsRoot)
        let models = ParakeetTranscriber.Models(root: modelsRoot, verifier: verifier)
        let nativeCalls = Mutex(0)
        let runtime = SpeechRuntime(
            makeDecoder: { _ in nativeCalls.withLock { $0 += 1 }; return BurstRecognizer() },
            makeDetector: { _ in nativeCalls.withLock { $0 += 1 }; return BurstDetector() }
        )

        // 1. recordOnly and afterStop allocate zero native models.
        for mode: TranscriptionMode in [.recordOnly, .afterStop] {
            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: NativeBudget(),
                mode: { mode },
                engine: { .parakeet(.init(models: models, runtime: runtime)) },
                pressure: PrecomputePressure(isAppActive: { true }, thermalState: { .nominal }, availableMemory: { 2 << 30 })
            )
            await pre.runOnce(noteID: note.id, captureURL: cafURL)
            #expect(nativeCalls.withLock { $0 } == 0, "\(mode) must allocate zero native models")
            #expect(!checkpoints.exists(note.id))
        }

        // 2. Thermal .serious yields immediately without allocating models.
        do {
            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: NativeBudget(),
                mode: { .transcribeWhileRecording },
                engine: { .parakeet(.init(models: models, runtime: runtime)) },
                pressure: PrecomputePressure(isAppActive: { true }, thermalState: { .serious }, availableMemory: { 2 << 30 })
            )
            await pre.runOnce(noteID: note.id, captureURL: cafURL)
            #expect(nativeCalls.withLock { $0 } == 0)
        }

        // 3. Low availableMemory() yields immediately without allocating models.
        do {
            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: NativeBudget(),
                mode: { .transcribeWhileRecording },
                engine: { .parakeet(.init(models: models, runtime: runtime)) },
                pressure: PrecomputePressure(isAppActive: { true }, thermalState: { .nominal }, availableMemory: { 10 << 20 })
            )
            await pre.runOnce(noteID: note.id, captureURL: cafURL)
            #expect(nativeCalls.withLock { $0 } == 0)
        }

        // 4. App backgrounding yields immediately without allocating models.
        do {
            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: NativeBudget(),
                mode: { .transcribeWhileRecording },
                engine: { .parakeet(.init(models: models, runtime: runtime)) },
                pressure: PrecomputePressure(isAppActive: { false }, thermalState: { .nominal }, availableMemory: { 2 << 30 })
            )
            await pre.runOnce(noteID: note.id, captureURL: cafURL)
            #expect(nativeCalls.withLock { $0 } == 0)
        }

        // 5. Held NativeBudget (saved-audio queue preemption) yields immediately without blocking or allocating models.
        do {
            let budget = NativeBudget()
            try await budget.acquire()
            defer { budget.release() }
            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: budget,
                mode: { .transcribeWhileRecording },
                engine: { .parakeet(.init(models: models, runtime: runtime)) },
                pressure: PrecomputePressure(isAppActive: { true }, thermalState: { .nominal }, availableMemory: { 2 << 30 })
            )
            await pre.runOnce(noteID: note.id, captureURL: cafURL)
            #expect(nativeCalls.withLock { $0 } == 0)
        }
    }

    // MARK: - Lane runners & deterministic fakes

    private struct ParakeetLaneResult {
        let note: Note
        let provenance: TranscriptProvenance?
        let appliedPrints: [SpeakerPrint]
        let precomputeCheckpointsSaved: Int
        let postStopDecodeCalls: Int
    }

    private func runParakeetLane(
        fullPCM: Data,
        growingPrefixPCM: Data?,
        tamperClipsAfterPrecompute: ((URL) throws -> Void)? = nil
    ) async throws -> ParakeetLaneResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let modelsRoot = dir.appendingPathComponent("models", isDirectory: true)
        try Self.installSparseModel(ModelCatalog.parakeet, in: modelsRoot)
        let store = try NoteStore(root: dir.appendingPathComponent("notes", isDirectory: true))
        var note = Note(title: "Meeting", audioFilename: "capture.caf")
        note.duration = Double(fullPCM.count / 2) / 48_000.0
        try await store.save(note)
        let cafURL = store.audioURL(for: note)

        let checkpoints = CheckpointFiles(notes: store)
        let provenance = ProvenanceFiles(notes: store)
        let verifier = ModelVerifier()
        verifier.markVerified(ModelCatalog.parakeet, in: modelsRoot)
        let models = ParakeetTranscriber.Models(root: modelsRoot, verifier: verifier)
        let budget = NativeBudget()

        let speakerEngines = DeterministicSpeakerEngines()
        let analyzer = DeterministicSpeakerAnalyzer(engines: speakerEngines)
        let savedCount = Mutex(0)

        if let prefix = growingPrefixPCM {
            try Self.writeCAF(to: cafURL, pcm: prefix, finalized: false)
            let preRuntime = SpeechRuntime(makeDecoder: { _ in BurstRecognizer() }, makeDetector: { _ in BurstDetector() })
            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: budget,
                mode: { .transcribeWhileRecording },
                engine: {
                    .parakeet(.init(
                        models: models,
                        runtime: preRuntime,
                        speakerEngines: { speakerEngines },
                        identifySpeakers: { true },
                        printsReady: { true }
                    ))
                },
                pressure: PrecomputePressure(isAppActive: { true }, thermalState: { .nominal }, availableMemory: { 2 << 30 }),
                safetyMarginFrames: 4_800,
                onCheckpointSaved: { _, _ in savedCount.withLock { $0 += 1 } }
            )
            await pre.runOnce(noteID: note.id, captureURL: cafURL)
            if let tamperClipsAfterPrecompute, let clipsURL = checkpoints.clipsURL(for: note.id) {
                try tamperClipsAfterPrecompute(clipsURL)
            }
        }

        // Stop finalizes the full CAF file (changing file length + mtime + data chunk header).
        try Self.writeCAF(to: cafURL, pcm: fullPCM, finalized: true)

        let postDecodes = Mutex(0)
        let postRuntime = SpeechRuntime(
            makeDecoder: { _ in BurstRecognizer(onDecode: { postDecodes.withLock { $0 += 1 } }) },
            makeDetector: { _ in BurstDetector() }
        )
        let transcriber = ParakeetTranscriber(models: models, runtime: postRuntime, availableMemory: { 2 << 30 }, thread: .speech)
        let appliedPrints = Mutex<[SpeakerPrint]>([])
        let host = TestJobHost(store: store, identifySpeakers: true) { analysis in
            appliedPrints.withLock { $0 = analysis.prints }
        }
        let jobRunner = TranscriptionJob(
            notes: store,
            transcriber: transcriber,
            analyzer: analyzer,
            checkpoints: checkpoints,
            provenance: provenance,
            host: host,
            clock: SystemClock(),
            budget: budget,
            availableMemory: { 2 << 30 }
        )

        let job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: .running, language: "", enqueuedAt: Date())
        let outcome = await jobRunner.run(job, stop: StopSignal()) { _ in }
        #expect(outcome == .done)

        let finalNote = try #require(await store.note(note.id))
        return ParakeetLaneResult(
            note: finalNote,
            provenance: provenance.load(note.id)?.provenance,
            appliedPrints: appliedPrints.withLock { $0 },
            precomputeCheckpointsSaved: savedCount.withLock { $0 },
            postStopDecodeCalls: postDecodes.withLock { $0 }
        )
    }

    private struct WhistleLaneResult {
        let outcome: JobOutcome
        let note: Note
        let provenance: TranscriptProvenance?
        let precomputeCheckpointsSaved: Int
        let postStopEarliestFrameRead: Int64
    }

    private func runWhistleLane(fullPCM: Data, growingPrefixPCM: Data?) async throws -> WhistleLaneResult {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try NoteStore(root: dir.appendingPathComponent("notes", isDirectory: true))
        var note = Note(title: "Whistle", audioFilename: "capture.caf")
        note.duration = Double(fullPCM.count / 2) / 48_000.0
        try await store.save(note)
        let cafURL = store.audioURL(for: note)

        let checkpoints = CheckpointFiles(notes: store)
        let provenance = ProvenanceFiles(notes: store)
        let budget = NativeBudget()
        let capability = WhistleCapability(arm64: true, operatingSystemSupported: true, cpuSupported: true,
                                           bundleVerified: true, pipelineAccepted: true, deviceAccepted: true)
        let backend = Self.deterministicWhistleBackend()
        let savedCount = Mutex(0)

        if let prefix = growingPrefixPCM {
            try Self.writeCAF(to: cafURL, pcm: prefix, finalized: false)
            let pre = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: budget,
                mode: { .transcribeWhileRecording },
                engine: { .whistle(.init(acceptance: { capability }, backend: backend, skipBundleVerification: true)) },
                pressure: PrecomputePressure(isAppActive: { true }, thermalState: { .nominal }, availableMemory: { 2 << 30 }),
                safetyMarginFrames: 4_800,
                onCheckpointSaved: { _, _ in savedCount.withLock { $0 += 1 } }
            )
            await pre.runOnce(noteID: note.id, captureURL: cafURL)
        }

        try Self.writeCAF(to: cafURL, pcm: fullPCM, finalized: true)

        let earliestRead = Mutex<Int64?>(nil)
        let trace = WhistleTranscriber.Trace(
            read: { range in
                earliestRead.withLock { current in
                    current = current.map { min($0, range.lowerBound) } ?? range.lowerBound
                }
            },
            submitted: { _ in },
            resultReady: { _ in }
        )
        let transcriber = WhistleTranscriber(
            acceptance: { capability },
            availableMemory: { 2 << 30 },
            trace: trace,
            backend: backend,
            skipBundleVerification: true
        )
        let host = TestJobHost(store: store, identifySpeakers: false) { _ in }
        let jobRunner = TranscriptionJob(
            notes: store,
            transcriber: transcriber,
            analyzer: NoSpeakersAnalyzer(),
            checkpoints: checkpoints,
            provenance: provenance,
            host: host,
            clock: SystemClock(),
            budget: budget,
            availableMemory: { 2 << 30 }
        )

        let job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: .running, language: "", enqueuedAt: Date())
        let outcome = await jobRunner.run(job, stop: StopSignal()) { _ in }
        let finalNote = try #require(await store.note(note.id))
        return WhistleLaneResult(
            outcome: outcome,
            note: finalNote,
            provenance: provenance.load(note.id)?.provenance,
            precomputeCheckpointsSaved: savedCount.withLock { $0 },
            postStopEarliestFrameRead: earliestRead.withLock { $0 ?? 0 }
        )
    }

    private func runWhistleJobWithRawCheckpoint(
        fullPCM: Data,
        mainJSON: String,
        backupJSON: String?
    ) async throws -> (outcome: JobOutcome, note: Note, earliestFrameRead: Int64) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = try NoteStore(root: dir.appendingPathComponent("notes", isDirectory: true))
        var note = Note(title: "WhistleRaw", audioFilename: "capture.caf")
        note.duration = Double(fullPCM.count / 2) / 48_000.0
        try await store.save(note)
        let cafURL = store.audioURL(for: note)
        try Self.writeCAF(to: cafURL, pcm: fullPCM, finalized: true)

        let checkpoints = CheckpointFiles(notes: store)
        let folder = checkpoints.directory(for: note.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(mainJSON.utf8).write(to: folder.appendingPathComponent(CheckpointFiles.filename))
        if let backupJSON {
            try Data(backupJSON.utf8).write(to: folder.appendingPathComponent(CheckpointFiles.backupFilename))
        }

        let capability = WhistleCapability(arm64: true, operatingSystemSupported: true, cpuSupported: true,
                                           bundleVerified: true, pipelineAccepted: true, deviceAccepted: true)
        let backend = Self.deterministicWhistleBackend()
        let earliestRead = Mutex<Int64?>(nil)
        let trace = WhistleTranscriber.Trace(
            read: { range in
                earliestRead.withLock { current in
                    current = current.map { min($0, range.lowerBound) } ?? range.lowerBound
                }
            },
            submitted: { _ in },
            resultReady: { _ in }
        )
        let transcriber = WhistleTranscriber(
            acceptance: { capability },
            availableMemory: { 2 << 30 },
            trace: trace,
            backend: backend,
            skipBundleVerification: true
        )
        let jobRunner = TranscriptionJob(
            notes: store,
            transcriber: transcriber,
            analyzer: NoSpeakersAnalyzer(),
            checkpoints: checkpoints,
            provenance: ProvenanceFiles(notes: store),
            host: TestJobHost(store: store, identifySpeakers: false) { _ in },
            clock: SystemClock(),
            budget: NativeBudget(),
            availableMemory: { 2 << 30 }
        )

        let job = Job(noteID: note.id, seq: 1, kind: .transcribe, state: .running, language: "", enqueuedAt: Date())
        let outcome = await jobRunner.run(job, stop: StopSignal()) { _ in }
        let finalNote = try #require(await store.note(note.id))
        return (outcome, finalNote, earliestRead.withLock { $0 ?? 0 })
    }

    private static func deterministicWhistleBackend() -> WhistleSessionBackend {
        let zeroVADState: WhistleVAD.State = {
            let filterData = try! JSONEncoder().encode(SpeechInputFilter())
            let filterJSON = String(decoding: filterData, as: UTF8.self)
            let json = #"{"filter":\#(filterJSON),"recurrent":[0]}"#
            return try! JSONDecoder().decode(WhistleVAD.State.self, from: Data(json.utf8))
        }()
        return WhistleSessionBackend(
            makeVAD: { _ in
                WhistleSessionBackend.VADHandle(
                    probability: { frame in
                        let peak = frame.map(abs).max() ?? 0
                        return peak >= 0.01 ? 0.9 : 0.05
                    },
                    state: { zeroVADState },
                    restore: { _ in }
                )
            },
            prepare: { _, _ in },
            transcribe: { samples, _, _, submitted, resultReady in
                submitted?()
                let dur = Double(samples.count) / 16_000.0
                let peakBucket = Int(((samples.map(abs).max() ?? 0) * 1000).rounded())
                let text = "seg\(samples.count)_\(peakBucket)"
                let end = max(0.1, dur - 0.05)
                let json = #"{"text":"\#(text)","language":"en","words":[{"word":"\#(text)","start":0.05,"end":\#(end),"probability":0.99}]}"#
                let res = try WhistleResult.parse(Data(json.utf8), samples: samples.count)
                await resultReady?()
                return res
            },
            close: { true }
        )
    }
}

// MARK: - Deterministic test doubles

private final class BurstRecognizer: SpeechDecoding {
    let onDecode: (@Sendable () -> Void)?
    init(onDecode: (@Sendable () -> Void)? = nil) { self.onDecode = onDecode }
    func decode(_ samples: [Float]) throws -> RecognizedTokens {
        onDecode?()
        let rate = Limits.asrRate
        var tokens: [String] = []
        var timestamps: [Float] = []
        var durations: [Float] = []
        let seconds = max(1, samples.count / rate)
        for s in 0..<seconds {
            let lo = s * rate
            let hi = min(samples.count, (s + 1) * rate)
            let peak = samples[lo..<hi].map(abs).max() ?? 0
            if peak >= 0.01 {
                let bucket = Int((peak * 100).rounded())
                tokens.append("▁b\(bucket)")
                timestamps.append(Float(s) + 0.3)
                durations.append(0.25)
            }
        }
        return RecognizedTokens(text: tokens.joined(), tokens: tokens, timestamps: timestamps, durations: durations)
    }
}

private final class BurstDetector: SpeechDetecting, @unchecked Sendable {
    private var fed: [Float] = []
    private var segments: [SpeechFeed.Segment] = []
    private var open: Int?
    func reset() { fed = []; segments = []; open = nil }
    func acceptWaveform(_ window: [Float]) {
        let start = fed.count
        fed += window
        let speech = window.contains { abs($0) >= 0.01 }
        if speech, open == nil { open = start }
        if !speech, let first = open { segments.append(.init(first, Array(fed[first..<start]))); open = nil }
    }
    func empty() -> Bool { segments.isEmpty }
    func front() -> SpeechFeed.Segment { segments[0] }
    func pop() { segments.removeFirst() }
    func flush() { if let first = open { segments.append(.init(first, Array(fed[first...]))); open = nil } }
}

private final class DeterministicDiarizer: StreamingDiarizer, @unchecked Sendable {
    var turns: [DiarizerTurn] = []
    var elapsedMs: Int64 = 0
    var state: DiarizerState { DiarizerState(cache: [0.5, -0.25], elapsedMs: elapsedMs, turns: turns) }

    init(restored: DiarizerState?) {
        if let restored {
            turns = restored.turns
            elapsedMs = restored.elapsedMs
        }
    }

    func process(_ audio: PcmAudio, startMs: Int64) throws -> [DiarizerTurn] {
        let durationMs = Int64(audio.samples.count) * 1000 / Int64(audio.sampleRate)
        let endMs = startMs + durationMs
        let split: Int64 = 35_000
        var windowTurns: [DiarizerTurn] = []
        if startMs < split {
            windowTurns.append(DiarizerTurn(startMs, min(endMs, split), 0))
        }
        if endMs > split {
            windowTurns.append(DiarizerTurn(max(startMs, split), endMs, 1))
        }
        turns.append(contentsOf: windowTurns)
        elapsedMs += 10
        return windowTurns
    }
}

private struct DeterministicSpeakerEngines: SpeakerEngines {
    func openDiarizer(restored: DiarizerState?) throws -> any StreamingDiarizer {
        DeterministicDiarizer(restored: restored)
    }

    func prints(_ audio: any PcmSource, windows: [String: [PrintWindow]],
                active: () throws -> Void) throws -> [String: Voiceprint] {
        var result: [String: Voiceprint] = [:]
        for (speaker, ranges) in windows {
            try active()
            var totalSamples = 0
            for range in ranges {
                let data = try audio.read(range.startSample, range.endSample - range.startSample)
                totalSamples += data.count
            }
            let slot: Float = speaker.hasSuffix("_2") ? 2.0 : 1.0
            let vector = [Float](repeating: slot / Float(VoiceprintModel.dimension).squareRoot(), count: VoiceprintModel.dimension)
            result[speaker] = Voiceprint(vector: vector, seconds: Double(totalSamples) / 16_000.0)
        }
        return result
    }

    func run<Value: Sendable>(_ work: @Sendable () throws -> Value) async throws -> Value {
        try work()
    }
}

private struct DeterministicSpeakerAnalyzer: SpeakerAnalyzing {
    let engines: any SpeakerEngines
    var modelInstallBytes: Int64 { 0 }
    func modelStatus() async -> ModelPartStatus { .ready }
    func refreshModelStatus() async -> ModelPartStatus { .ready }
    func printsReady() async -> Bool { true }
    func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {}
    func analyze(url: URL, words: [Word], allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        SpeakerAnalysis(turns: [], prints: [])
    }
    func streamingEngines() async -> (any SpeakerEngines)? { engines }
}

private struct NoSpeakersAnalyzer: SpeakerAnalyzing {
    var modelInstallBytes: Int64 { 0 }
    func modelStatus() async -> ModelPartStatus { .notDownloaded }
    func refreshModelStatus() async -> ModelPartStatus { .notDownloaded }
    func printsReady() async -> Bool { false }
    func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {}
    func analyze(url: URL, words: [Word], allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        SpeakerAnalysis(turns: [], prints: [])
    }
}

private struct TestJobHost: TranscriptionJobHost {
    let store: NoteStore
    let identifySpeakers: Bool
    let onApply: @Sendable (SpeakerAnalysis) -> Void

    func jobSettings() async -> JobSettings {
        JobSettings(allowSpeechDownload: false, identifySpeakers: identifySpeakers, allowSpeakerDownload: false)
    }

    func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws {
        onApply(analysis)
        _ = try await store.mutate(noteID) { note in
            if let transcript = analysis.transcript {
                note.transcript = transcript
            }
        }
    }
}
