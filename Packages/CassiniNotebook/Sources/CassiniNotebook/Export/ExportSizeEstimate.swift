import Foundation

/// Estimates the exported `.opus` Cassini file size before encoding (`D106` L-62).
///
/// `PortableExportService` reuses an existing Ogg Opus stream directly and re-encodes every other
/// format (M4A recordings, WAV/MP3/FLAC imports) to 48 kbps mono Ogg Opus (`OpusAudio.encode`).
public enum ExportSizeEstimate {
    /// Target bitrate of `OpusAudio.encode` (48 kbps = 6,000 bytes/second).
    public static let opusBytesPerSecond: Int64 = 48_000 / 8
    /// Fixed allowance for Ogg page framing and Cassini manifest tags.
    public static let containerOverheadBytes: Int64 = 4_096

    /// Returns the estimated size in bytes of the exported `.opus` file, or `nil` when neither an
    /// existing Ogg Opus file nor a positive duration is available.
    public static func cassiniBytes(note: Note, audioURL: URL?) -> Int64? {
        if let audioURL,
           (try? ImportClassifier.sniff(fileAt: audioURL)) == .oggOpus,
           let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path))?[.size] as? NSNumber,
           size.int64Value > 0 {
            return size.int64Value
        }
        guard note.duration.isFinite, note.duration > 0 else { return nil }
        let audioBytes = Int64((note.duration * Double(opusBytesPerSecond)).rounded())
        let transcriptBytes = note.transcript.reduce(Int64(0)) { $0 + Int64($1.text.utf8.count) }
        return audioBytes + containerOverheadBytes + transcriptBytes
    }
}
