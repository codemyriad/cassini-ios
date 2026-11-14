import SwiftUI
import CassiniEngine
import CassiniNotebook

/// An On-device models row: the part, its size and its status in its tone (Ready teal, Downloading and Checking blue,
/// Pending amber, Failed red, Not downloaded plain). Only a Not downloaded and a Failed row are buttons.
struct ModelRowView: View {
    let row: ModelRow
    var modelName: String? = nil
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

    @ViewBuilder private func content(chevron: Bool) -> some View {
        if #available(iOS 26.0, *) {
            HStack(spacing: 12) {
                partLabel
                Spacer(minLength: 8)
                statusLabel(chevron: chevron)
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        } else {
            // iOS 18's List row clipping check flags two wrapping columns in an HStack; LabeledContent stacks at AX sizes.
            LabeledContent {
                HStack(spacing: 12) { statusLabel(chevron: chevron) }
            } label: {
                partLabel
            }
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
        }
    }

    private var partLabel: some View {
        VStack(alignment: .leading, spacing: 2) {
            Group {
                if let modelName { Text(verbatim: modelName) } else { Text(row.part.settingsLabel) }
            }.foregroundStyle(Color.ink)
            if let size = row.size.label(locale: locale) {
                Text(size).font(.subheadline).foregroundStyle(Color.muted)
            }
        }
    }

    @ViewBuilder private func statusLabel(chevron: Bool) -> some View {
        Text(row.status.label).font(.subheadline.weight(.medium)).foregroundStyle(row.status.tone.color)
            .multilineTextAlignment(.trailing)
        if chevron {
            Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
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
    /// The row's subtitle; nil when it has none.
    func label(locale: Locale) -> String? {
        switch self {
        case .included: String(localized: "Included with Cassini", table: "Settings")
        case .managedBySystem: String(localized: "Managed by iOS", table: "Settings")
        case .bytes(let bytes): SizeCopy.text(bytes, locale: locale)
        case .precision(let precision, let bytes):
            String(localized: "\(precision) · \(SizeCopy.text(bytes, locale: locale))", table: "Settings",
                   comment: "The speech row's subtitle: the model's precision and its download (INT8 · 443 MB)")
        case .includedWith: String(localized: "Comes with telling speakers apart", table: "Settings")
        case .noModel: nil
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
}
