import CassiniCore

/// How far a note can trust the Cassini document it was imported from (Android `TrustUi` and `NoteMapping.trust`).
public enum DocumentTrust: String, CaseIterable, Hashable, Sendable {
    /// The audio matches the transcript exactly.
    case verified
    /// The audio could not be checked.
    case notVerified
    /// The audio changed after the transcript was made.
    case audioChanged
    /// The file's Cassini data is damaged.
    case unreadable
    /// A newer version of the format.
    case newerFormat

    public init(_ state: DocumentState) {
        switch state {
        case .ok: self = .verified
        case .unverified, .plainAudio: self = .notVerified
        case .staleAudio: self = .audioChanged
        case .unreadable, .invalidMetadata: self = .unreadable
        case .unknownFormat: self = .newerFormat
        }
    }

    /// The trust of `note`'s document; nil for a note that did not come from one.
    public static func of(_ note: Note) -> DocumentTrust? { note.document.map { DocumentTrust($0.state) } }

    /// Whether the note shows its trust banner (Android `NoteViewModel.trustBanner`). By default every state but
    /// verified shows it, and not verified only until "Play anyway"; `toggled`, flipped by the trust chip, inverts that.
    public static func showsBanner(_ info: DocumentInfo, toggled: Bool = false) -> Bool {
        shownByDefault(info) != toggled
    }

    /// Whether the banner offers "Play anyway", which sets `trustAcknowledged` and plays.
    public var offersPlayAnyway: Bool { self == .notVerified }

    private static func shownByDefault(_ info: DocumentInfo) -> Bool {
        switch DocumentTrust(info.state) {
        case .verified: false
        case .notVerified: !info.trustAcknowledged
        case .audioChanged, .unreadable, .newerFormat: true
        }
    }
}
