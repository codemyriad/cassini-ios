import SwiftUI
import CassiniEngine
import CassiniNotebook

/// An On-device models row: the part, its size and its status in its tone (Ready teal, Downloading and Checking blue,
/// Pending amber, Failed red, Not downloaded plain). Only a Not downloaded and a Failed row are buttons.
struct ModelRowView: View {
    let row: ModelRow
    let open: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        if row.status.opensModelDownload {
            Button(action: open) { content(chevron: true) }
                .accessibilityHint(Text("Opens the model download", tableName: "Settings"))
        } else {
            content(chevron: false)
        }
    }

    private func content(chevron: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(row.part.settingsLabel).foregroundStyle(Color.ink)
                Text(row.size.label(locale: locale)).font(.subheadline).foregroundStyle(Color.muted)
            }
            Spacer(minLength: 8)
            Text(row.status.label).font(.subheadline.weight(.medium)).foregroundStyle(row.status.tone.color)
                .multilineTextAlignment(.trailing)
            if chevron {
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

extension ModelPart {
    /// The part's name on its Settings row.
    var settingsLabel: String {
        switch self {
        case .speech: String(localized: "Speech recognition", table: "Settings")
        case .speakers: String(localized: "Telling speakers apart", table: "Settings")
        case .voices: String(localized: "Recognising saved voices", table: "Settings")
        }
    }
}

extension ModelSize {
    func label(locale: Locale) -> String {
        switch self {
        case .managedBySystem: String(localized: "Managed by iOS", table: "Settings")
        case .bytes(let bytes): bytes.formatted(.byteCount(style: .file).locale(locale))
        case .includedWith: String(localized: "Comes with telling speakers apart", table: "Settings")
        }
    }
}

extension ModelRowStatus {
    var label: String {
        switch self {
        case .ready: String(localized: "Ready", table: "Settings")
        case .downloading(let percent): String(localized: "Downloading \(percent)%", table: "Settings")
        case .checking: String(localized: "Checking files", table: "Settings")
        case .pending: String(localized: "Downloads with next transcription", table: "Settings")
        case .notDownloaded: String(localized: "Not downloaded", table: "Settings")
        case .failed: String(localized: "Download failed — tries again next time", table: "Settings")
        case .unavailable: String(localized: "Not available", table: "Settings")
        }
    }

    var tone: Tone {
        switch self {
        case .ready: .ok
        case .downloading, .checking: .info
        case .pending: .warn
        case .failed: .error
        case .notDownloaded, .unavailable: .plain
        }
    }
}
