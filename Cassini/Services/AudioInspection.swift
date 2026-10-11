import AVFoundation
import Foundation

struct AudioInspection: Sendable {
    let duration: Double
    let waveform: [Float]
    static func inspect(_ url: URL) async throws -> AudioInspection {
        try await Task.detached(priority: .utility) {
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
                guard let channel = buffer.floatChannelData?[0], buffer.frameLength > 0 else { levels.append(0.1); continue }
                var sum: Float = 0
                for sample in 0..<Int(buffer.frameLength) { sum += channel[sample] * channel[sample] }
                levels.append(min(1, max(0.04, sqrt(sum / Float(buffer.frameLength)) * 4)))
            }
            return AudioInspection(duration: duration, waveform: levels)
        }.value
    }
}

enum AudioArchive {
    static func compress(source: URL, destination: URL) async throws {
        let asset = AVURLAsset(url: source)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw AudioError.unreadable
        }
        try await export.export(to: destination, as: .m4a)
    }
}

enum AudioError: LocalizedError {
    case empty, unreadable, microphoneDenied, noInput, startFailed, storageLow, busy
    var errorDescription: String? {
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
