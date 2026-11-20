import CryptoKit
import Foundation
import Testing
import CassiniNotebook

/// Verifies the vendored Wave 0 head-start vectors (`cassini-ux/vectors/head-start/`):
/// - `transcription-mode-vectors.json`
/// - `mobile-prefix-checkpoint-vectors.json`
/// - `LiveCAFReader` on growing and finalized mono PCM16LE `.caf` files.
@Suite struct HeadStartVectorTests {
    private static func resourceData(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: nil, subdirectory: "head-start"))
        return try Data(contentsOf: url)
    }

    @Test func vendoredVectorDigestsMatchUpstreamPin() throws {
        let upstreamData = try Self.resourceData("UPSTREAM.json")
        let upstream = try #require(try JSONSerialization.jsonObject(with: upstreamData) as? [String: Any])
        let files = try #require(upstream["files"] as? [String: [String: String]])
        for (name, meta) in files {
            let data = try Self.resourceData(name)
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(digest == meta["sha256"], "SHA-256 mismatch for vendored \(name)")
        }
    }

    @Test func transcriptionModeVectorsPass() throws {
        let data = try Self.resourceData("transcription-mode-vectors.json")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["schema"] as? String == "cassini.head-start.transcription-mode-vectors.v1")
        #expect(root["defaultMode"] as? String == TranscriptionMode.defaultMode.rawValue)
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)

        for entry in cases {
            let id = try #require(entry["id"] as? String)
            let input = try #require(entry["input"] as? [String: Any])
            let expected = try #require(entry["expected"] as? [String: Any])
            let rawMode: Any? = input["rawMode"] is NSNull ? nil : input["rawMode"]
            let policy = TranscriptionModePolicy.evaluate(
                rawMode: rawMode,
                hasForegroundSavedJob: input["hasForegroundSavedJob"] as? Bool ?? false,
                manualTranscribeRequested: input["manualTranscribeRequested"] as? Bool ?? false,
                platformSupportsPrecompute: input["platformSupportsPrecompute"] as? Bool ?? true
            )
            #expect(policy.resolvedMode.rawValue == expected["resolvedMode"] as? String, "\(id): resolvedMode")
            #expect(policy.fellBackToDefault == expected["fellBackToDefault"] as? Bool, "\(id): fellBackToDefault")
            #expect(policy.spawnWorkerDuringRecording == expected["spawnWorkerDuringRecording"] as? Bool, "\(id): spawnWorkerDuringRecording")
            #expect(policy.autoEnqueueOnStop == expected["autoEnqueueOnStop"] as? Bool, "\(id): autoEnqueueOnStop")
            #expect(policy.savedTranscriptStateOnStop == expected["savedTranscriptStateOnStop"] as? String, "\(id): savedTranscriptStateOnStop")
            #expect(policy.enqueueOnManualRequest == expected["enqueueOnManualRequest"] as? Bool, "\(id): enqueueOnManualRequest")
            #expect(policy.preemptActiveFollower == expected["preemptActiveFollower"] as? Bool, "\(id): preemptActiveFollower")
        }
    }

    @Test func mobilePrefixCheckpointVectorsPass() throws {
        let data = try Self.resourceData("mobile-prefix-checkpoint-vectors.json")
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["schema"] as? String == "cassini.head-start.mobile-prefix-checkpoint-vectors.v1")
        let cases = try #require(root["cases"] as? [[String: Any]])
        #expect(!cases.isEmpty)

        for entry in cases {
            let id = try #require(entry["id"] as? String)
            let checkpoint = try #require(entry["checkpoint"] as? [String: Any])
            let expectedFile = try #require(entry["expectedFile"] as? [String: Any])
            let expectedDecision = try #require(entry["expectedDecision"] as? [String: Any])

            let outcome = MobileCheckpointValidator.validate(checkpoint: checkpoint, expected: expectedFile)
            #expect(outcome.decision.rawValue == expectedDecision["decision"] as? String, "\(id): decision")
            let expectedMatchMode = expectedDecision["matchMode"] as? String
            #expect(outcome.matchMode?.rawValue == expectedMatchMode, "\(id): matchMode")
            let expectedReason = expectedDecision["reason"] as? String
            #expect(outcome.reason == expectedReason, "\(id): reason")
            #expect(outcome.failUserJob == expectedDecision["failUserJob"] as? Bool, "\(id): failUserJob")
        }
    }

    @Test func liveCAFReaderReadsGrowingAndFinalizedFilesAndHashesPrefix() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("capture.caf")

        // Write a growing CAF file (data chunk size = -1) with 48 kHz mono PCM16LE.
        let pattern: [Int16] = [123, -456, 789, -1011]
        let initialFrames = 96_000 // 2 s
        var pcm = Data(capacity: initialFrames * 2)
        for i in 0..<initialFrames {
            var sample = pattern[i % pattern.count].littleEndian
            withUnsafeBytes(of: &sample) { pcm.append(contentsOf: $0) }
        }
        try Self.writeCAF(to: url, sampleRate: 48_000, pcm: pcm, declaredSize: -1)

        let reader = try LiveCAFReader(url: url)
        defer { reader.close() }
        #expect(reader.sampleRate == 48_000)
        #expect(reader.bytesPerFrame == 2)
        #expect(reader.layout.declaredDataBytes == nil)
        #expect(try reader.availableFrames() == UInt64(initialFrames))
        #expect(try reader.safeThroughFrame(safetyMarginFrames: 4_800) == UInt64(initialFrames - 4_800))

        let committed: UInt64 = 48_048 // 1 s + 48-frame FIR lookahead
        let prefixHash = try reader.prefixSHA256(committedFrames: committed)
        let directHash = SHA256.hash(data: pcm.prefix(Int(committed) * 2)).map { String(format: "%02x", $0) }.joined()
        #expect(prefixHash == directHash)

        // Append trailing 1 s and finalize header (like AVAudioRecorder.stop()).
        var fullPCM = pcm
        for i in 0..<48_000 {
            var sample = Int16((i % 200) - 100).littleEndian
            withUnsafeBytes(of: &sample) { fullPCM.append(contentsOf: $0) }
        }
        try Self.writeCAF(to: url, sampleRate: 48_000, pcm: fullPCM, declaredSize: Int64(fullPCM.count + 4))

        let expectation = try #require(LiveCAFReader.prefixExpectation(for: url, committedUnitCount: committed))
        #expect(expectation.sourceSampleRateHz == 48_000)
        #expect(expectation.resamplerLookaheadFrames == 48)
        #expect(expectation.finalizedUnitCount == UInt64(initialFrames + 48_000))
        #expect(expectation.prefixSha256 == prefixHash)

        // Validate CheckpointState with differing whole-file signature succeeds via committedPrefix.
        let cp = CheckpointState(
            source: "capture.caf",
            signature: "old:0",
            model: "parakeet-model",
            segments: [],
            doneMs: 1_000,
            totalMs: 0,
            elapsedMs: 50,
            origin: .precompute,
            recognitionSampleCount: 16_000,
            committedPrefix: CommittedPrefix(
                kind: .cafPcm16LeFrames,
                sourceSampleRateHz: 48_000,
                committedUnitCount: committed,
                prefixSha256: prefixHash
            )
        )
        let expected = CheckpointState.Expected(
            source: "capture.caf",
            signature: CheckpointState.signature(of: url),
            model: "parakeet-model",
            prefix: expectation
        )
        try cp.validate(expected)

        // Mutating a single frame inside the committed prefix causes validation to reject.
        var mutatedPCM = fullPCM
        mutatedPCM[0] ^= 0x01
        try Self.writeCAF(to: url, sampleRate: 48_000, pcm: mutatedPCM, declaredSize: Int64(mutatedPCM.count + 4))
        let mutatedExpectation = try #require(LiveCAFReader.prefixExpectation(for: url, committedUnitCount: committed))
        #expect(throws: CheckpointState.Mismatch.signature) {
            try cp.validate(CheckpointState.Expected(
                source: "capture.caf",
                signature: CheckpointState.signature(of: url),
                model: "parakeet-model",
                prefix: mutatedExpectation
            ))
        }
    }

    private static func writeCAF(to url: URL, sampleRate: Double, pcm: Data, declaredSize: Int64) throws {
        var out = Data()
        // File header: 'caff', version 1, flags 0
        out.append(contentsOf: "caff".utf8)
        out.append(contentsOf: [0, 1, 0, 0])
        // 'desc' chunk: size 32
        out.append(contentsOf: "desc".utf8)
        appendBE(&out, Int64(32))
        appendBE(&out, sampleRate.bitPattern)
        out.append(contentsOf: "lpcm".utf8)
        appendBE(&out, UInt32(2)) // little-endian integer
        appendBE(&out, UInt32(2)) // bytesPerPacket
        appendBE(&out, UInt32(1)) // framesPerPacket
        appendBE(&out, UInt32(1)) // channelsPerFrame
        appendBE(&out, UInt32(16)) // bitsPerChannel
        // 'data' chunk
        out.append(contentsOf: "data".utf8)
        appendBE(&out, declaredSize)
        appendBE(&out, UInt32(0)) // mEditCount
        out.append(pcm)
        try out.write(to: url)
    }

    private static func appendBE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }
}
