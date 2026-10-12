import CassiniCore
import Foundation

/// What a file's first bytes say it is. The name the file came with never decides this.
public enum ImportContent: Equatable, Sendable {
    /// An Ogg stream whose first packet is an OpusHead: a Cassini document or plain Opus audio.
    case oggOpus
    /// Any other container, with the file extension its signature names (`mp3`, `m4a`, `wav`, …), or nil when the
    /// bytes match none Cassini knows. AVFoundation decides whether it holds audio.
    case other(fileExtension: String?)
}

/// Sniffs imported files by content (Android `AudioFiles.sniff`, plus the containers AVFoundation opens).
public enum ImportClassifier {
    /// How many bytes the sniff reads.
    public static let sniffBytes = 64

    public static func sniff(_ head: [UInt8]) -> ImportContent {
        if OggOpus.looksLikeOpus(head) { return .oggOpus }
        return .other(fileExtension: containerExtension(head))
    }

    /// Sniffs the first `sniffBytes` of the file.
    public static func sniff(fileAt url: URL) throws -> ImportContent {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        return sniff([UInt8](try handle.read(upToCount: sniffBytes) ?? Data()))
    }

    /// The extension of the container whose signature starts `head`; nil when none matches.
    static func containerExtension(_ head: [UInt8]) -> String? {
        func ascii(_ offset: Int, _ text: String) -> Bool {
            let bytes = Array(text.utf8)
            return head.count >= offset + bytes.count && Array(head[offset..<offset + bytes.count]) == bytes
        }
        if ascii(0, "RIFF") && ascii(8, "WAVE") { return "wav" }
        if ascii(0, "FORM") && ascii(8, "AIFF") { return "aiff" }
        if ascii(0, "FORM") && ascii(8, "AIFC") { return "aifc" }
        if ascii(0, "caff") { return "caf" }
        if ascii(0, "fLaC") { return "flac" }
        if ascii(0, "#!AMR-WB\n") { return "awb" }
        if ascii(0, "#!AMR\n") { return "amr" }
        if ascii(0, "OggS") { return "ogg" }
        if ascii(4, "ftyp") { return ascii(8, "3gp") || ascii(8, "3g2") ? "3gp" : "m4a" }
        if ascii(0, "ID3") { return "mp3" }
        if head.count >= 2 && head[0] == 0xFF && head[1] & 0xE0 == 0xE0 {
            // Frame sync: ADTS AAC has layer bits 00, MPEG audio (MP3) does not.
            return head[1] & 0x06 == 0 ? "aac" : "mp3"
        }
        return nil
    }
}
