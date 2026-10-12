import Foundation

/**
 * What a reader concluded about a file. The raw value is the state name of SPEC.md "Trust and integrity";
 * [unreadable] is reported only by [CassiniDocument.readChecked], for a file that could not be opened or read.
 */
public enum DocumentState: String, Codable, CaseIterable, Hashable, Sendable {
    case plainAudio = "plain-audio"
    case unknownFormat = "unknown-cassini-format"
    case invalidMetadata = "invalid-cassini-metadata"
    case unverified
    case staleAudio = "stale-audio"
    case ok
    case unreadable

    public var code: String { rawValue }
}

extension CassiniDocument {
    /**
     * [read], except that a file that cannot be opened or read is [DocumentState.unreadable], with the error in
     * [warnings], instead of plain audio. A read error later in the audio leaves the document unverified, as in [read].
     */
    public static func readChecked(_ url: URL, verify: Bool = true) -> CassiniDocument {
        read(verify: verify, reportsIOErrors: true) { try FileSource(url) }
    }
}
