import SwiftUI
import CassiniEngine
import CassiniNotebook

/// "Transcribe on this device": consent for downloading the models a note, or a standalone download, needs.
struct ModelDownloadView: View {
    let noteID: UUID?
    var part: ModelPart? = nil
    var parakeetOnly = false
    @Environment(ProcessingStore.self) private var processing
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var model: ModelDownloadModel?

    var body: some View {
        Group {
            if let model, let plan = model.plan {
                ModelDownloadContent(model: model, plan: plan)
            } else {
                Color.paper.ignoresSafeArea()
            }
        }
        .background(Color.paper)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard model == nil else { return }
            guard let ports = parakeetOnly ? processing.parakeetDownload : processing.modelDownload else { dismiss(); return }
            let model = ModelDownloadModel(noteID: noteID, ports: ports, part: part)
            model.onEffect = { effect in
                switch effect {
                case .close: dismiss()
                case .openLicenses: router.push(.licenses)
                }
            }
            self.model = model
            await model.load()
        }
    }
}

private struct ModelDownloadContent: View {
    let model: ModelDownloadModel
    let plan: ModelDownloadPlan
    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    OrbitMark(size: 56)
                    Text("Transcribe on this device", tableName: "Transcription")
                        .font(.system(.largeTitle, design: .serif)).foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    intro(total: plan.totalDownloadBytes).font(.title3).foregroundStyle(Color.muted)
                    VStack(spacing: 0) {
                        ForEach(Array(plan.missing.enumerated()), id: \.element) { index, part in
                            if index > 0 { Divider().padding(.leading, 16) }
                            HStack(spacing: 12) {
                                Text(part.label).font(.body).foregroundStyle(Color.ink)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let bytes = plan.downloadBytes[part] {
                                    Text(SizeCopy.text(bytes, locale: locale))
                                        .font(.subheadline.monospacedDigit()).foregroundStyle(Color.muted)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .accessibilityElement(children: .combine)
                        }
                    }.cardBackground(radius: Radius.control)
                    if let language = model.speechLanguage {
                        // D59 (2): Apple Speech hears only the language set in Settings.
                        Text("Cassini recognises speech in \(name(of: language)). To transcribe another language, change it in Settings › Speech language.", tableName: "Transcription", comment: "On the consent screen of devices that use Apple’s speech models. %@ is the speech language’s name, e.g. Italian (Italy). ‘Settings › Speech language’ names the screen and the setting.")
                            .font(.subheadline).foregroundStyle(Color.muted)
                            .accessibilityIdentifier("speechLanguageLine")
                    }
                    Text("Needs about \(SizeCopy.text(plan.requiredFreeBytes, locale: locale)) free while installing. Each file is checked before it is used.", tableName: "Transcription")
                        .font(.subheadline).foregroundStyle(Color.muted)
                    Button(action: model.openSources) {
                        Text("Where the models come from · Privacy", tableName: "Transcription")
                    }
                    .font(.subheadline.weight(.medium)).tint(.ember)
                    .frame(minHeight: HitTarget.minimum)
                }
                .padding(.top, 8).padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            ModelDownloadActions(model: model)
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
        .readableWidth()
    }

    /// The language's name as the Settings picker shows it, in the app's language.
    private func name(of identifier: String) -> String { locale.localizedString(forIdentifier: identifier) ?? identifier }

    /// The body, with the one-time download when every part tells its size (Parakeet devices): "about **531 MB**",
    /// the figure in bold ink and kept on one line (Android `ModelDownloadBody`).
    private func intro(total: Int64?) -> Text {
        guard let total else {
            return Text("Cassini needs a one-time download. After that, recognising words and telling voices apart happen on this device, even offline. Your audio stays here.", tableName: "Transcription")
        }
        let size = SizeCopy.text(total, locale: locale).replacingOccurrences(of: " ", with: "\u{00A0}")
        var text = AttributedString(String(localized: "Cassini needs a one-time download of about \(size). After that, recognising words and telling voices apart happen on this device, even offline. Your audio stays here.", table: "Transcription", comment: "Model download screen body with the total download, such as 531 MB"))
        if let range = text.range(of: size) {
            text[range].font = .title3.weight(.bold)
            text[range].foregroundColor = Color.ink
        }
        return Text(text)
    }
}

private struct ModelDownloadActions: View {
    let model: ModelDownloadModel

    var body: some View {
        VStack(spacing: 10) {
            if let bytes = model.noSpaceBytes {
                Banner(spec: Notices.download(.notEnoughStorage, requiredFreeBytes: bytes, announce: true),
                       onAction: { _ in Task { await model.download() } })
                    .padding(.bottom, 6)
            }
            Button { Task { await model.download() } } label: {
                ZStack {
                    primaryLabel.opacity(model.busy ? 0 : 1)
                    if model.busy { ProgressView().tint(.compatibilityWhite) }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.busy)
            Button(action: model.notNow) { Text("Not now — keep the audio", tableName: "Transcription") }
                .font(.body.weight(.medium)).tint(.ink)
                .frame(maxWidth: .infinity, minHeight: HitTarget.minimum)
                .disabled(model.busy)
        }
    }

    private var primaryLabel: Text {
        if model.identifiesSpeakers { Text("Download and identify speakers", tableName: "Transcription") }
        else if model.withNote { Text("Download and transcribe", tableName: "Transcription") }
        else { Text("Download", tableName: "Transcription") }
    }
}

extension ModelPart {
    /// The part's name on the model download screen.
    var label: String {
        switch self {
        case .speech: String(localized: "Speech recognition", table: "Transcription")
        case .speakers: String(localized: "Telling speakers apart", table: "Transcription")
        case .voices: String(localized: "Recognising saved voices", table: "Transcription")
        }
    }
}
