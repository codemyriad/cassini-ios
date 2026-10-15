import Foundation
import CassiniNotebook

/// `work/clips.pcm` (Android's `PcmFile`): the voice clips of a streaming job as raw little-endian 32-bit floats at
/// 16 kHz, appended as the windows come. A checkpoint counts its samples (`SpeakerCheckpoint.clipSamples`), so a
/// resumed run cuts the file back to that count, and the file is flushed to disk before each checkpoint that counts
/// it. Not thread-safe: the inference thread owns it during a decode, the job after it.
public final class ClipFile: ClipStore, @unchecked Sendable {
    public let url: URL
    public let sampleRate = CassiniNotebook.Limits.asrRate
    public private(set) var sampleCount: Int
    private let handle: FileHandle

    /// Opens `url`, creating it (and its folder, but not the folder's parent) when it is missing. `keeping` samples
    /// stay and anything after them goes; nil keeps none, as a fresh run starts. Throws when the file holds fewer than
    /// `keeping` samples.
    public init(url: URL, keeping: Int?) throws {
        self.url = url
        let folder = url.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: folder.path) {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }
        if keeping == nil || !FileManager.default.fileExists(atPath: url.path) {
            guard FileManager.default.createFile(atPath: url.path, contents: nil) else { throw CocoaError(.fileWriteUnknown) }
        }
        handle = try FileHandle(forUpdating: url)
        let bytes = try handle.seekToEnd()
        let kept = keeping ?? 0
        guard bytes >= UInt64(kept) * 4 else {
            try? handle.close()
            throw CocoaError(.fileReadCorruptFile)
        }
        try handle.truncate(atOffset: UInt64(kept) * 4)
        sampleCount = kept
    }

    deinit { try? handle.close() }

    public func append(_ samples: ArraySlice<Float>) throws {
        guard !samples.isEmpty else { return }
        try handle.seekToEnd()
        try handle.write(contentsOf: DiarizerState.bytes(Array(samples)))
        sampleCount += samples.count
    }

    public func read(_ start: Int, _ count: Int) throws -> [Float] {
        precondition(start >= 0 && count >= 0 && start + count <= sampleCount)
        try handle.seek(toOffset: UInt64(start) * 4)
        let data = try handle.read(upToCount: count * 4) ?? Data()
        guard data.count == count * 4, let floats = DiarizerState.floats(data) else { throw CocoaError(.fileReadCorruptFile) }
        return floats
    }

    /// Flushes what was appended to disk.
    public func sync() throws { try handle.synchronize() }
}

/// Clips in memory, for a run without a work folder (tests) and the whole-file analysis.
public final class MemoryClips: ClipStore, @unchecked Sendable {
    public let sampleRate = CassiniNotebook.Limits.asrRate
    public private(set) var samples: [Float] = []
    public var sampleCount: Int { samples.count }

    public init(_ samples: [Float] = []) { self.samples = samples }

    public func append(_ samples: ArraySlice<Float>) throws { self.samples += samples }

    public func read(_ start: Int, _ count: Int) throws -> [Float] { Array(samples[start..<(start + count)]) }
}
