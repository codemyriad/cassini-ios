import SwiftUI
import CassiniNotebook

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
            // Transcribe again on a changed or unreadable document waits for the Note screen's fresh-transcript
            // question, so only Play anyway is offered.
            let actions: [BannerAction] = trust.offersPlayAnyway && playAnyway != nil ? [.playAnyway] : []
            Banner(spec: BannerSpec(Self.kind(trust), actions: actions), onAction: { _ in playAnyway?() })
                .accessibilityIdentifier("documentTrustBanner")
        }
    }

    static func kind(_ trust: DocumentTrust) -> BannerKind {
        switch trust {
        case .verified: .trustVerified
        case .notVerified: .trustNotVerified
        case .audioChanged: .trustAudioChanged
        case .unreadable: .trustUnreadable
        case .newerFormat: .trustNewerFormat
        }
    }
}
