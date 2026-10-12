import CassiniCore
import Foundation

extension DocumentState {
    /// The upper-case name used inside stored failure codes (`DOCUMENT_STALE_AUDIO`); Android uses the same names.
    public var name: String {
        switch self {
        case .plainAudio: "PLAIN_AUDIO"
        case .unknownFormat: "UNKNOWN_FORMAT"
        case .invalidMetadata: "INVALID_METADATA"
        case .unverified: "UNVERIFIED"
        case .staleAudio: "STALE_AUDIO"
        case .ok: "OK"
        case .unreadable: "UNREADABLE"
        }
    }
}

/// What the import of a Cassini document found, kept so the note can show its trust state without reading the file.
public struct DocumentInfo: Codable, Hashable, Sendable {
    public var state: DocumentState
    public var warnings: [String]
    /// Transcript variants that could not be read, by variant id, with the reason.
    public var unavailableVariants: [String: String]
    /// "Play anyway" was chosen for a document that is not `ok`.
    public var trustAcknowledged: Bool
    /// The app that wrote the document, from its manifest.
    public var vendor: String?

    public init(state: DocumentState, warnings: [String] = [], unavailableVariants: [String: String] = [:],
                trustAcknowledged: Bool = false, vendor: String? = nil) {
        self.state = state; self.warnings = warnings; self.unavailableVariants = unavailableVariants
        self.trustAcknowledged = trustAcknowledged; self.vendor = vendor
    }
}
