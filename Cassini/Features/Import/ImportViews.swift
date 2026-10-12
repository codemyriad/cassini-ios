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

/// The trust chip of a note imported from a Cassini document (Android `trustChip`).
struct DocumentTrustChip: View {
    let trust: DocumentTrust

    var body: some View {
        Text(Self.label(trust)).font(.caption.weight(.medium)).foregroundStyle(tone.color)
            .padding(.horizontal, 8).padding(.vertical, 4).background(tone.background, in: Capsule())
            .accessibilityIdentifier("documentTrust")
    }

    private var tone: Tone {
        switch trust {
        case .verified: .ok
        case .notVerified, .audioChanged: .warn
        case .unreadable, .newerFormat: .error
        }
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

/// The trust banner of a note from a Cassini document that is not verified (Android TRUST_* banners).
struct DocumentTrustNotice: View {
    let info: DocumentInfo

    var body: some View {
        if DocumentTrust.showsBanner(info) {
            let (title, body) = Self.copy(DocumentTrust(info.state))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(body).font(.subheadline)
            }
            .foregroundStyle(Color.ink).frame(maxWidth: .infinity, alignment: .leading).padding(16)
            .background(Color.ember.opacity(0.08), in: RoundedRectangle(cornerRadius: Radius.control))
            .accessibilityElement(children: .combine)
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
