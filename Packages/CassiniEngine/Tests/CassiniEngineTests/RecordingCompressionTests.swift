import AVFoundation
import Foundation
import Testing
import CassiniAudio
import CassiniCore
import CassiniNotebook
@testable import CassiniEngine

/// Real AppleM4A exports: decoded frame counts / asset edit lists need not agree with AVAudioPlayer at a second boundary.
@MainActor @Suite struct RecordingCompressionTests {
    // The recorder uses 48 kHz; 44.1 kHz also exercises AAC endpoints when the host preset preserves the input rate.
    @Test(arguments: [2, 11], [48_000.0, 44_100.0])
    func compressedDurationMatchesPlayer(seconds: Int, sourceRate: Double) async throws {
        let h = try RecordingHarness(audioProcessing: ArchiveAudioProcessing())
        defer { h.tearDown() }
        #expect(h.controller.start())
        await h.controller.operations?.value
        let id = try h.active.noteID
        let capture = try #require(h.capture.url)
        try await writeCapture(capture, seconds: seconds, sampleRate: sourceRate)
        h.capture.elapsed = Double(seconds)
        #expect(try await AudioInspection.inspect(capture).duration == Double(seconds))

        h.controller.finish()
        await h.controller.settle()
        let note = try #require(await h.note(id))
        #expect(note.audioFilename == "audio.m4a")
        let url = h.store.audioURL(for: note)
        let inspection = try await AudioInspection.inspect(url)
        let playerDuration = try await CancellableFileWork.run { try AVAudioPlayer(contentsOf: url).duration }
        let asset = AVURLAsset(url: url)
        let assetDuration = try await asset.load(.duration).seconds
        let track = try #require(try await asset.loadTracks(withMediaType: .audio).first)
        let trackDuration = try await track.load(.timeRange).duration.seconds
        let (frameDuration, sampleRate) = try await CancellableFileWork.run {
            let file = try AVAudioFile(forReading: url)
            return (Double(file.length) / file.processingFormat.sampleRate, file.processingFormat.sampleRate)
        }
        print("D-1066 \(seconds)s at \(sampleRate)Hz: asset=\(assetDuration), track=\(trackDuration), frames=\(frameDuration), inspection=\(inspection.duration), player=\(playerDuration)")
        #expect(note.duration == playerDuration)
        #expect(inspection.duration == playerDuration)
        #expect(TimeText.clock(note.duration) == TimeText.clock(playerDuration))
        let reloaded = try NoteStore(root: h.root)
        try await reloaded.load()
        #expect(await reloaded.note(id)?.duration == playerDuration)
        #expect(!FileManager.default.fileExists(atPath: capture.path))
        #expect(h.handoff.handedOff == [id])
    }

    /// The issue's 44.1 kHz AAC endpoints, even on hosts whose AppleM4A preset keeps 48 kHz unchanged.
    @Test(arguments: [88_192.0 / 44_100, 485_056.0 / 44_100])
    func aCompressedEndpointBelowAWholeSecondReplacesTheCaptureDuration(endpoint: Double) async throws {
        let originalDuration = endpoint.rounded(.up)
        let h = try RecordingHarness(audioProcessing: BoundaryAudioProcessing(original: originalDuration, endpoint: endpoint))
        defer { h.tearDown() }
        #expect(h.controller.start())
        await h.controller.operations?.value
        let id = try h.active.noteID
        h.capture.elapsed = originalDuration
        h.controller.finish()
        await h.controller.settle()
        let note = try #require(await h.note(id))
        #expect(note.audioFilename == "audio.m4a")
        #expect(note.duration == endpoint)
        #expect(TimeText.clock(note.duration) == TimeText.clock(endpoint))
        #expect(TimeText.clock(note.duration) != TimeText.clock(originalDuration))
        #expect(note.waveform == [0.5, 0.5], "keep the capture's waveform")
    }

    enum DuringInspection: CaseIterable, Sendable {
        case renameAndTrash, delete, inspectionFailure, writeFailure
    }

    @Test(arguments: DuringInspection.allCases)
    func reinspectionPreservesConcurrentChangesAndOriginalOnFailure(action: DuringInspection) async throws {
        let gate = CompressedInspectionGate()
        let audio = ArchiveAudioProcessing(gate: gate, inspectionFails: action == .inspectionFailure)
        let h = try RecordingHarness(audioProcessing: audio)
        defer { h.tearDown() }
        var failures: [UUID] = []
        h.controller.onCompressionFailed = { failures.append($0) }
        #expect(h.controller.start())
        await h.controller.operations?.value
        let id = try h.active.noteID
        let capture = try #require(h.capture.url)
        try await writeCapture(capture, seconds: 2)
        h.capture.elapsed = 2
        h.controller.finish()
        await gate.waitUntilEntered()
        let original = try #require(await h.note(id))
        #expect(original.audioFilename == "capture.caf" && original.duration == 2)
        #expect(FileManager.default.fileExists(atPath: capture.path))
        let compressed = capture.deletingLastPathComponent().appendingPathComponent("audio.m4a")
        #expect(FileManager.default.fileExists(atPath: compressed.path))
        let trashedAt = Date(timeIntervalSince1970: 1_800_000_000)
        switch action {
        case .renameAndTrash:
            _ = try await h.store.update(id) {
                $0.title = "Renamed during compression"; $0.trashedAt = trashedAt
                $0.status = .audioOnly; $0.failure = .long
            }
        case .delete: try await h.store.delete(id)
        case .writeFailure: h.notes.failUpdates = true
        case .inspectionFailure: break
        }
        await gate.open()
        await h.controller.settle()
        let reloaded = try NoteStore(root: h.root)
        try await reloaded.load()
        let stored = await reloaded.note(id)
        #expect(stored == (await h.note(id)))
        switch action {
        case .renameAndTrash:
            let note = try #require(stored)
            #expect(note.title == "Renamed during compression" && note.trashedAt == trashedAt)
            #expect(note.status == .audioOnly && note.failure == .long)
            #expect(note.audioFilename == "audio.m4a")
            let playerDuration = try await CancellableFileWork.run { try AVAudioPlayer(contentsOf: compressed).duration }
            #expect(note.duration == playerDuration)
            #expect(!FileManager.default.fileExists(atPath: capture.path))
            #expect(h.handoff.handedOff.isEmpty)
        case .delete:
            #expect(stored == nil)
            #expect(!FileManager.default.fileExists(atPath: capture.deletingLastPathComponent().path))
            #expect(h.handoff.handedOff.isEmpty)
        case .inspectionFailure, .writeFailure:
            #expect(stored == original, "failed finalization must retain the CAF metadata and waveform")
            #expect(FileManager.default.fileExists(atPath: capture.path))
            #expect(!FileManager.default.fileExists(atPath: compressed.path))
            #expect(h.handoff.handedOff == [id], "the readable original still reaches transcription")
            if action == .inspectionFailure { #expect(failures == [id]) }
        }
        #expect(h.controller.finalizing.isEmpty && h.handoff.finalizing.isEmpty)
    }

    private func writeCapture(_ url: URL, seconds: Int, sampleRate: Double = 48_000) async throws {
        try await CancellableFileWork.run {
            // The same on-disk format as AVCaptureAdapter's recorder.
            let settings: [String: Any] = [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false]
            let file = try AVAudioFile(forWriting: url, settings: settings)
            let format = file.processingFormat
            let frames = AVAudioFrameCount(Double(seconds) * sampleRate)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
            buffer.frameLength = frames
            for i in 0..<Int(frames) { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / sampleRate)) * 0.3 }
            try file.write(from: buffer)
        }
    }
}

private struct ArchiveAudioProcessing: AudioProcessing {
    var gate: CompressedInspectionGate? = nil
    var inspectionFails = false
    func inspect(_ url: URL) async throws -> AudioSummary {
        if url.pathExtension == "m4a" {
            await gate?.enter()
            if inspectionFails { throw AudioError.unreadable }
        }
        let inspection = try await AudioInspection.inspect(url) { #expect(!Thread.isMainThread) }
        return AudioSummary(duration: inspection.duration, waveform: inspection.waveform)
    }
    func compress(_ source: URL, to destination: URL) async throws {
        try await AudioArchive.compress(source: source, destination: destination)
    }
    func decodeOpus(_ source: URL, to destination: URL) async throws { throw AudioError.unreadable }
    func encodeOpus(_ source: URL, to destination: URL) async throws { throw AudioError.unreadable }
}

/// Suspends after export, before the replacement is inspected; no sleeps or timing-dependent races.
private actor CompressedInspectionGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }
    func enter() async {
        await withCheckedContinuation { continuation in
            release = continuation
            entered = true
            entry?.resume(); entry = nil
        }
    }
    func open() { release?.resume(); release = nil }
}

private struct BoundaryAudioProcessing: AudioProcessing {
    let original: Double
    let endpoint: Double
    func inspect(_ url: URL) async throws -> AudioSummary {
        AudioSummary(duration: url.pathExtension == "m4a" ? endpoint : original, waveform: [0.5, 0.5])
    }
    func compress(_ source: URL, to destination: URL) async throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
    func decodeOpus(_ source: URL, to destination: URL) async throws { throw AudioError.unreadable }
    func encodeOpus(_ source: URL, to destination: URL) async throws { throw AudioError.unreadable }
}
