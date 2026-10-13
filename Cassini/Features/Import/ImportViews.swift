import SwiftUI
import CassiniNotebook

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
