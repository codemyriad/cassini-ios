import SwiftUI
import CassiniNotebook

/// "Importing <name>…" while files are imported, and the last import error until it is dismissed or another import
/// starts (Android banners IMPORTING and IMPORT_*). WP9's notice centre takes these over from `ImportTracker`.
struct ImportActivity: View {
    @Environment(ImportStore.self) private var imports

    var body: some View {
        let tracker = imports.tracker
        if let name = tracker.running.last {
            Label { Text("Importing \(name)…", tableName: "Import") } icon: { Image(systemName: "arrow.down.doc") }
                .font(.subheadline).foregroundStyle(Color.muted)
                .accessibilityIdentifier("importing")
        }
        if let failure = tracker.failure {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Self.title(failure.kind)).font(.subheadline.weight(.semibold))
                    Text(Self.body(failure.kind)).font(.subheadline)
                }
                .foregroundStyle(Color.ink).frame(maxWidth: .infinity, alignment: .leading).padding(16)
                .background(Tone.error.background, in: RoundedRectangle(cornerRadius: Radius.control))
                .accessibilityElement(children: .combine)
                Button { tracker.dismissFailure() } label: {
                    Image(systemName: "xmark").frame(width: HitTarget.minimum, height: HitTarget.minimum)
                }
                .accessibilityLabel(Text("Dismiss", tableName: "Import"))
            }
            .accessibilityIdentifier("importFailure")
        }
    }

    static func title(_ kind: ImportFailureKind) -> String {
        switch kind {
        case .tooLarge: String(localized: "File too large", table: "Import")
        case .noSpace: String(localized: "Not enough space to import", table: "Import")
        case .cannotOpen, .cannotSave: String(localized: "Can’t open this file", table: "Import")
        }
    }

    static func body(_ kind: ImportFailureKind) -> String {
        switch kind {
        case .tooLarge: return String(localized: "Choose a file under 4 GB.", table: "Import")
        case .noSpace(let bytes):
            let size = bytes.formatted(.byteCount(style: .file))
            return String(localized: "This file needs about \(size) free. Free some space and try again.", table: "Import")
        case .cannotOpen, .cannotSave: return String(localized: "It doesn’t look like audio Cassini can read.", table: "Import")
        }
    }
}

extension DocumentTrust {
    /// The tone of the chip and of the banner (Android `TrustUi` and the TRUST_* banner tones).
    var tone: Tone {
        switch self {
        case .verified: .ok
        case .notVerified, .audioChanged: .warn
        case .unreadable, .newerFormat: .error
        }
    }
}

/// The trust chip of a note imported from a Cassini document (Android `trustChip`); tapping it shows or hides the
/// trust banner.
struct DocumentTrustChip: View {
    let trust: DocumentTrust
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            Text(Self.label(trust)).font(.caption.weight(.medium)).foregroundStyle(trust.tone.color)
                .padding(.horizontal, 8).padding(.vertical, 4).background(trust.tone.background, in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("documentTrust")
    }

    static func label(_ trust: DocumentTrust) -> String {
        switch trust {
        case .verified: String(localized: "Verified", table: "Import")
        case .notVerified: String(localized: "Not verified", table: "Import")
        case .audioChanged: String(localized: "Audio changed", table: "Import")
        case .unreadable: String(localized: "Can’t read transcript", table: "Import")
        case .newerFormat: String(localized: "Newer format", table: "Import")
        }
    }
}

/// The trust banner of a note from a Cassini document (Android TRUST_* banners): shown by default unless verified
/// (not verified until "Play anyway"), and the other way round once the chip is tapped.
struct DocumentTrustNotice: View {
    let info: DocumentInfo
    let toggled: Bool
    /// "Play anyway"; nil when the note cannot play.
    let playAnyway: (() -> Void)?

    var body: some View {
        if DocumentTrust.showsBanner(info, toggled: toggled) {
            let trust = DocumentTrust(info.state)
            let (title, body) = Self.copy(trust)
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.subheadline.weight(.semibold))
                    Text(body).font(.subheadline)
                }
                .accessibilityElement(children: .combine)
                if trust.offersPlayAnyway, let playAnyway {
                    Button(String(localized: "Play anyway", table: "Import"), action: playAnyway)
                        .font(.subheadline.weight(.semibold)).frame(minHeight: HitTarget.minimum)
                        .accessibilityIdentifier("playAnyway")
                }
            }
            .foregroundStyle(Color.ink).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(trust.tone.background, in: RoundedRectangle(cornerRadius: Radius.control))
            .accessibilityIdentifier("documentTrustBanner")
        }
    }

    static func copy(_ trust: DocumentTrust) -> (String, String) {
        switch trust {
        case .verified:
            (String(localized: "Verified", table: "Import"),
             String(localized: "Audio matches the transcript exactly. Everything works.", table: "Import"))
        case .notVerified:
            (String(localized: "Not verified", table: "Import"),
             String(localized: "The audio could not be checked, so word timing may be off.", table: "Import"))
        case .audioChanged:
            (String(localized: "Audio changed since transcription", table: "Import"),
             String(localized: "Word timing may not match what you hear.", table: "Import"))
        case .unreadable:
            (String(localized: "Transcript can’t be read", table: "Import"),
             String(localized: "The file’s Cassini data is damaged. The audio still plays.", table: "Import"))
        case .newerFormat:
            (String(localized: "Newer Cassini format", table: "Import"),
             String(localized: "This version can’t be read here yet. The audio still plays.", table: "Import"))
        }
    }
}
