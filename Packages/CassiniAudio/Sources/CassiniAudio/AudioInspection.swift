import AVFoundation
import Foundation

public struct AudioInspection: Sendable {
    public let duration: Double
    public let waveform: [Float]
    public static func inspect(_ url: URL) async throws -> AudioInspection {
        try await inspect(url, onBuffer: {})
    }

    // An event seam for cancellation during actual AVFoundation work, without timing assumptions.
    static func inspect(_ url: URL, onBuffer: @escaping @Sendable () throws -> Void) async throws -> AudioInspection {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: url)
            guard file.length > 0, file.processingFormat.sampleRate > 0 else { throw AudioError.empty }
            let duration = Double(file.length) / file.processingFormat.sampleRate
            // Sample 96 short windows; memory and work stay bounded for long recordings.
            let count = 96
            let capacity: AVAudioFrameCount = 2048
            guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: capacity) else { throw AudioError.unreadable }
            var levels: [Float] = []
            for index in 0..<count {
                try Task.checkCancellation()
                file.framePosition = min(file.length - 1, AVAudioFramePosition(Double(index) / Double(count) * Double(file.length)))
                try file.read(into: buffer, frameCount: capacity)
                try onBuffer()
                try Task.checkCancellation()
                guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { levels.append(0.1); continue }
                levels.append(min(1, max(0.04, acLevel(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength))) * 4)))
            }
            try Task.checkCancellation()
            return AudioInspection(duration: duration, waveform: levels)
        }
        return try await withTaskCancellationHandler {
            do {
                let result = try await worker.value
                try Task.checkCancellation()
                return result
            } catch { try Task.checkCancellation(); throw error }
        } onCancel: {
            worker.cancel()
        }
    }

    /// The RMS of `samples` with their mean taken off (D26.1): a microphone's DC offset is not sound.
    /// `sqrt(max(0, mean(x²) − mean(x)²))`, as the shared meters measure it.
    static func acLevel(_ samples: UnsafeBufferPointer<Float>) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sum = 0.0, squares = 0.0
        for sample in samples { sum += Double(sample); squares += Double(sample) * Double(sample) }
        let mean = sum / Double(samples.count)
        return Float(max(0, squares / Double(samples.count) - mean * mean).squareRoot())
    }
}

public enum AudioArchive {
    /// Writes `source` as M4A to `destination`, replacing a copy an earlier, unfinished attempt left there.
    public static func compress(source: URL, destination: URL) async throws {
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError.unreadable
        }
        try await export.export(to: destination, as: .m4a)
    }
}

public enum AudioError: LocalizedError {
    case empty, unreadable, microphoneDenied, noInput, startFailed, storageLow, busy
    public var errorDescription: String? {
        switch self {
        case .empty: "This audio file is empty. Choose a recording with audio."
        case .unreadable: "This audio format could not be opened. Try M4A, WAV, MP3, AIFF, or CAF."
        case .microphoneDenied: "Microphone access is off. Enable it for Cassini in Settings to record."
        case .noInput: "No microphone is available. Connect an audio input and try again."
        case .startFailed: "The microphone could not start. Check your audio connection and try again."
        case .storageLow: "Your device is running low on storage. Free up space before recording or importing."
        case .busy: "Finish your current recording first."
        }
    }
}
