#if DEBUG
import Foundation
import Synchronization
import CassiniCore
import CassiniEngine

/// Stands in for AVFoundation and libopus (Android's `FakeProbe`). Like AVFoundation it needs a whole container: an
/// MP4 opens only when its `moov` box is present, an MP3 when it starts with an ID3 tag or a frame sync, a WAV or CAF
/// by its header. Ogg Opus "decodes" when its pages scan, and the "encoder" writes Opus silence of the same length.
public final class FakeAudioProcessing: AudioProcessing {
    private struct State {
        var inspections = 0
        var error: (any Error)?
        var onInspect: (@Sendable () -> Void)?
        var decodeError: (any Error)?
    }

    private let state = Mutex(State())
    private let duration: TimeInterval

    public init(duration: TimeInterval = 15.84) { self.duration = duration }

    /// How many files `inspect` was asked to read.
    public var inspections: Int { state.withLock { $0.inspections } }

    /// From now on every `inspect` throws `error` (an I/O error while the file is read), or works again with nil.
    public func failInspections(with error: (any Error)?) { state.withLock { $0.error = error } }

    /// From now on every `decodeOpus` throws `error` (say an `OSStatus` of a full disk), or works again with nil.
    public func failDecodes(with error: (any Error)?) { state.withLock { $0.decodeError = error } }

    /// Runs `action` at the start of every `inspect`, e.g. to cancel the import that asked.
    public func onInspect(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.onInspect = action } }

    public func inspect(_ url: URL) async throws -> AudioSummary {
        let (error, action) = state.withLock { state -> ((any Error)?, (@Sendable () -> Void)?) in
            state.inspections += 1
            return (state.error, state.onInspect)
        }
        action?()
        // As AVFoundation's loading does, a cancelled task stops the read.
        try Task.checkCancellation()
        if let error { throw error }
        let bytes = [UInt8](try Data(contentsOf: url))
        let text = String(decoding: bytes.prefix(4096), as: UTF8.self)
        func ascii(_ offset: Int, _ tag: String) -> Bool {
            bytes.count >= offset + tag.utf8.count && Array(bytes[offset..<offset + tag.utf8.count]) == Array(tag.utf8)
        }
        let readable = (ascii(4, "ftyp") && text.contains("moov"))
            || ascii(0, "ID3") || (bytes.count > 1 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)
            || (ascii(0, "RIFF") && ascii(8, "WAVE")) || ascii(0, "caff")
        guard readable else { throw CocoaError(.fileReadCorruptFile) }
        return AudioSummary(duration: duration, waveform: [0.5, 0.5])
    }

    public func compress(_ source: URL, to destination: URL) async throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }

    /// Writes a `caff` file when `source` is Ogg Opus whose pages scan; throws otherwise, or the error set with
    /// `failDecodes(with:)`.
    public func decodeOpus(_ source: URL, to destination: URL) async throws {
        if let error = state.withLock({ $0.decodeError }) { throw error }
        let info = try OggOpus.scan(source)
        guard info.validFraming, info.sampleCount > 0 else { throw CassiniError("Unsupported or damaged Opus stream") }
        try Data("caff".utf8).write(to: destination)
    }

    /// Writes Opus silence as long as `duration`.
    public func encodeOpus(_ source: URL, to destination: URL) async throws {
        _ = try await inspect(source)
        let head = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let tags = CassiniDocument.tagsPacket([])
        let packets = max(1, Int(duration * 50))
        let stream = OggOpus.Stream(head: head, tags: tags, audio: Array(repeating: [0xF8, 0xFF, 0xFE], count: packets),
                                    finalGranule: Int64(packets * 960), validFraming: true)
        try Data(try OggOpus.mux(stream, tags: tags)).write(to: destination)
    }
}
#endif
