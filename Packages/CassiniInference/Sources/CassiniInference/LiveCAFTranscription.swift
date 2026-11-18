import Foundation
import CassiniAudio
import CassiniCore
import CassiniWhistle

/// In-memory drafts. The caller owns the foreground recording lifetime and may
/// coalesce wakeups. Finish the stream to obtain a settled tail, or cancel to prioritize the saved-audio job.
public enum LiveCAFTranscription {
    public enum Event: Sendable {
        case revision(fromMs: Int64, throughMs: Int64, settledMs: Int64, words: [Word])
        case skipped(fromFrame: UInt64, toFrame: UInt64)
    }

    public typealias Events = @Sendable (Event) -> Void

    static func follow(url: URL, wakes: AsyncStream<Void>,
                       decode: @Sendable ([Float]) async throws -> [Word], events: Events) async throws {
        var cursor: UInt64 = 0
        var windowStart: Int64 = 0
        var origin: Int64 = 0
        var settled: Int64 = 0
        var anchor: Word?
        var window: [Float] = []
        var sinceDecode = 0
        var fir = try WhistleResampler(rate: 48_000)
        let stride = 24_000, maxWindow = 128_000, contextMs: Int64 = 2_000

        func publish(final: Bool) async throws {
            guard !window.isEmpty, final || sinceDecode >= stride else { return }
            try Task.checkCancellation()
            let start = origin + windowStart / 16
            let end = origin + (windowStart + Int64(window.count)) / 16
            let words = window.contains(where: { $0 != 0 }) ? try await decode(window) : []
            try Task.checkCancellation()
            let placed = words.compactMap { word -> Word? in
                let from = min(end, start + max(0, word.startMs))
                let to = min(end, start + max(0, word.endMs))
                let midpoint = from + (to - from) / 2
                guard to >= from, midpoint >= settled, midpoint < end else { return nil }
                if let anchor, word.text.caseInsensitiveCompare(anchor.text) == .orderedSame,
                   abs(from - anchor.startMs) <= 120, abs(to - anchor.endMs) <= 120 {
                    return nil
                }
                return Word(word.speaker, from, to, word.text)
            }
            // Advance only to the end of a whole word well inside this window.
            // A later hypothesis may move its timestamps, but cannot overwrite
            // part of the settled word at an arbitrary time cutoff.
            if let last = placed.last(where: { $0.endMs <= end - contextMs }), last.endMs > settled {
                anchor = last
            }
            let boundary = final ? end : max(settled, anchor?.endMs ?? settled)
            events(.revision(fromMs: settled, throughMs: end, settledMs: boundary, words: placed))
            settled = boundary
            sinceDecode = 0
            if !final {
                let trim = max(0, window.count - (maxWindow - stride))
                window.removeFirst(trim)
                windowStart += Int64(trim)
            }
        }

        func append(_ pcm: [Float]) async throws {
            var at = 0
            while at < pcm.count {
                let count = min(pcm.count - at, stride - sinceDecode)
                window.append(contentsOf: pcm[at..<at + count])
                sinceDecode += count
                at += count
                try await publish(final: false)
            }
        }

        func drain(allowSkip: Bool) async throws {
            while true {
                try Task.checkCancellation()
                let frame = cursor
                guard let block = try await InferenceThread.speech.run({
                    try LiveCAFReader.read(url, fromFrame: frame)
                }) else { return }
                if allowSkip, block.availableThroughFrame - cursor > 48_000 * 8 {
                    let resume = block.availableThroughFrame - 48_000 * 2
                    events(.skipped(fromFrame: cursor, toFrame: resume))
                    cursor = resume
                    origin = Int64(resume / 48)
                    settled = origin
                    anchor = nil
                    windowStart = 0
                    window.removeAll(keepingCapacity: true)
                    sinceDecode = 0
                    fir = try WhistleResampler(rate: 48_000)
                    continue
                }
                let pcm = block.pcm16LE.withUnsafeBytes { bytes in
                    (0..<block.frameCount).map {
                        Float(Int16(littleEndian: bytes.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self))) / 32768
                    }
                }
                cursor += UInt64(block.frameCount)
                try await append(fir.feed(pcm))
            }
        }

        for await _ in wakes { try await drain(allowSkip: true) }
        try Task.checkCancellation()
        try await drain(allowSkip: false)
        try await append(fir.feed([], final: true))
        try await publish(final: true)
    }
}
