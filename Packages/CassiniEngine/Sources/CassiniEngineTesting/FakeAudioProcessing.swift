#if DEBUG
import Foundation
import Synchronization
import CassiniCore
import CassiniEngine

/// Stands in for AVFoundation and libopus (Android's `FakeProbe`). Like AVFoundation it needs a whole container: an
/// MP4 opens only when its `moov` box is present, an MP3 when it starts with an ID3 tag or a frame sync, a WAV or CAF
/// by its header. With `opensAnyFile` every file that exists opens instead, for tests whose captures are a few stand-in
/// bytes. Compression copies the file, Ogg Opus "decodes" when its pages scan, and the "encoder" writes Opus silence of
/// the summary's length.
public final class FakeAudioProcessing: AudioProcessing {
    private struct State {
        var summary: AudioSummary
        var inspections = 0
        var error: (any Error)?
        var onInspect: (@Sendable () -> Void)?
        var decodeError: (any Error)?
        var compressFails = false
        var held = false
        var compressed: [URL] = []
    }

    private let state: Mutex<State>
    private let opensAnyFile: Bool

    /// Every file that opens lasts `duration`.
    public convenience init(duration: TimeInterval = 15.84, opensAnyFile: Bool = false) {
        self.init(summary: AudioSummary(duration: duration, waveform: [0.5, 0.5]), opensAnyFile: opensAnyFile)
    }

    /// Every file that opens reads as `summary`.
    public init(summary: AudioSummary, opensAnyFile: Bool = false) {
        state = Mutex(State(summary: summary))
        self.opensAnyFile = opensAnyFile
    }

    /// How many files `inspect` was asked to read.
    public var inspections: Int { state.withLock { $0.inspections } }
    /// The compressed files written so far.
    public var compressed: [URL] { state.withLock { $0.compressed } }

    /// From now on every `inspect` throws `error` (an I/O error while the file is read), or works again with nil.
    public func failInspections(with error: (any Error)?) { state.withLock { $0.error = error } }

    /// From now on every file reads as `summary`, or none opens with nil.
    public func set(summary: AudioSummary?) {
        state.withLock { state in
            if let summary { state.summary = summary; state.error = nil } else { state.error = CocoaError(.fileReadCorruptFile) }
        }
    }

    /// From now on every `decodeOpus` throws `error` (say an `OSStatus` of a full disk), or works again with nil.
    public func failDecodes(with error: (any Error)?) { state.withLock { $0.decodeError = error } }

    /// From now on every `compress` fails, or works again.
    public func set(compressFails: Bool) { state.withLock { $0.compressFails = compressFails } }

    /// While held, every compression waits before it starts.
    public func set(held: Bool) { state.withLock { $0.held = held } }

    /// Runs `action` at the start of every `inspect`, e.g. to cancel the import that asked.
    public func onInspect(_ action: @escaping @Sendable () -> Void) { state.withLock { $0.onInspect = action } }

    public func inspect(_ url: URL) async throws -> AudioSummary {
        let (summary, error, action) = state.withLock { state -> (AudioSummary, (any Error)?, (@Sendable () -> Void)?) in
            state.inspections += 1
            return (state.summary, state.error, state.onInspect)
        }
        action?()
        // As AVFoundation's loading does, a cancelled task stops the read.
        try Task.checkCancellation()
        if let error { throw error }
        let bytes = [UInt8](try Data(contentsOf: url))
        guard opensAnyFile || Self.isContainer(bytes) else { throw CocoaError(.fileReadCorruptFile) }
        return summary
    }

    public func compress(_ source: URL, to destination: URL) async throws {
        while state.withLock({ $0.held }) { try await Task.sleep(for: .milliseconds(5)) }
        if state.withLock({ $0.compressFails }) { throw CocoaError(.fileWriteUnknown) }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
        state.withLock { $0.compressed.append(destination) }
    }

    /// Writes a `caff` file when `source` is Ogg Opus whose pages scan; throws otherwise, or the error set with
    /// `failDecodes(with:)`.
    public func decodeOpus(_ source: URL, to destination: URL) async throws {
        if let error = state.withLock({ $0.decodeError }) { throw error }
        let info = try OggOpus.scan(source)
        guard info.validFraming, info.sampleCount > 0 else { throw CassiniError("Unsupported or damaged Opus stream") }
        try Data("caff".utf8).write(to: destination)
    }

    /// Writes Opus silence as long as the summary.
    public func encodeOpus(_ source: URL, to destination: URL) async throws {
        let duration = try await inspect(source).duration
        let head = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]
        let tags = CassiniDocument.tagsPacket([])
        let packets = max(1, Int(duration * 50))
        let stream = OggOpus.Stream(head: head, tags: tags, audio: Array(repeating: [0xF8, 0xFF, 0xFE], count: packets),
                                    finalGranule: Int64(packets * 960), validFraming: true)
        try Data(try OggOpus.mux(stream, tags: tags)).write(to: destination)
    }

    private static func isContainer(_ bytes: [UInt8]) -> Bool {
        let text = String(decoding: bytes.prefix(4096), as: UTF8.self)
        func ascii(_ offset: Int, _ tag: String) -> Bool {
            bytes.count >= offset + tag.utf8.count && Array(bytes[offset..<offset + tag.utf8.count]) == Array(tag.utf8)
        }
        return (ascii(4, "ftyp") && text.contains("moov"))
            || ascii(0, "ID3") || (bytes.count > 1 && bytes[0] == 0xFF && bytes[1] & 0xE0 == 0xE0)
            || (ascii(0, "RIFF") && ascii(8, "WAVE")) || ascii(0, "caff")
    }
}
#endif
