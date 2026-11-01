import SwiftUI
import CassiniEngine
import CassiniInference

/// "Source code and notices": a row per notice, licence or text; a row opens its text, selectable, in a pane of its
/// own. "Source code on GitHub" opens the browser. The opened row is kept with the scene.
struct LicensesView: View {
    @Environment(\.openURL) private var openURL
    @SceneStorage("licenses.open") private var savedEntry: String?
    @State private var model: LicensesModel

    /// `models` is the model root, whose installed revisions keep the model host's notices.
    init(models: URL) {
        _model = State(initialValue: LicensesModel { try await LicensesView.text($0, models: models) })
    }

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                ForEach(model.entries, id: \.self) { entry in
                    Button { Task { await model.open(entry) } } label: {
                        SettingsRowLabel(title: entry.title, subtitle: entry.subtitle)
                    }
                }
            }
        }
        .paperListBackground()
        .navigationTitle(Text("Source code and notices", tableName: "Settings")).navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: Binding(get: { model.open }, set: { if $0 == nil { model.closeText() } })) { text in
            LicenseTextPane(text: text)
        }
        .task {
            model.onEffect = { effect in
                switch effect {
                case .openURL(let url): openURL(url)
                }
            }
            await model.restore(savedEntry.flatMap(LicenseEntry.init(rawValue:)))
        }
        .onChange(of: model.opened) { _, entry in savedEntry = entry?.rawValue }
    }

    /// The bundled files and the model host's notices of an installed model, read off the main actor.
    @Sendable private static func text(_ entry: LicenseEntry, models: URL) async throws -> String {
        let notice: @Sendable () -> String? = {
            ModelCatalog.installedNotice(in: models).flatMap { try? String(contentsOf: $0, encoding: .utf8) }
        }
        let texts = LicenseTexts(downloads: ModelCatalog.downloads, notice: notice) { name in
            let parts = name.split(separator: ".", maxSplits: 1).map(String.init)
            guard let url = Bundle.main.url(forResource: parts[0], withExtension: parts.count > 1 ? parts[1] : nil) else {
                throw CocoaError(.fileReadNoSuchFile)
            }
            return try String(contentsOf: url, encoding: .utf8)
        }
        return try await Task.detached { try texts.text(entry) }.value
    }
}

/// The text of an opened row: licences in small mono, the notices and the privacy text as paragraphs.
private struct LicenseTextPane: View {
    let text: LicenseText

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: text.entry.isLicenceText ? 12 : 10) {
                ForEach(Array(text.paragraphs.enumerated()), id: \.offset) { _, paragraph in
                    Text(verbatim: paragraph)
                        .font(text.entry.isLicenceText ? .system(.footnote, design: .monospaced) : .body)
                        .foregroundStyle(text.entry.isLicenceText ? Color.muted : Color.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(20)
            .readableWidth()
        }
        .background(Color.paper)
        .navigationTitle(text.entry.title).navigationBarTitleDisplayMode(.inline)
    }
}

extension LicenseEntry {
    var title: String {
        switch self {
        case .cassini: ProductName.full
        case .thirdParty: String(localized: "Third-party notices", table: "Settings")
        case .models: String(localized: "Model notices", table: "Settings")
        case .modelSources: String(localized: "Where the models come from", table: "Settings")
        case .privacy: String(localized: "Privacy", table: "Settings")
        case .sourceCode: String(localized: "Source code on GitHub", table: "Settings")
        }
    }

    var subtitle: String {
        switch self {
        case .cassini: "GNU General Public License v3"
        case .thirdParty: String(localized: "Libraries Cassini uses and their licences", table: "Settings")
        case .models: String(localized: "Licences of the speech and voice models", table: "Settings")
        case .modelSources: String(localized: "The servers Cassini downloads models from", table: "Settings")
        case .privacy: String(localized: "What Cassini keeps on this device and what it sends", table: "Settings")
        case .sourceCode: sourceCodeURL.absoluteString.replacingOccurrences(of: "https://", with: "")
        }
    }
}
