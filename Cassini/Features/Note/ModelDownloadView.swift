import SwiftUI
import CassiniEngine
import CassiniNotebook

/// A route-backed full-screen offer preserves navigation restoration and returns to its caller on Close.
struct ModelDownloadView: View {
    let noteID: UUID?
    var part: ModelPart? = nil
    var parakeetOnly = false
    var declineTurnsOff = false
    @Environment(\.dismiss) private var dismiss
    @State private var presented = false
    @State private var didPresent = false

    var body: some View {
        Color.paper.ignoresSafeArea()
            .navigationBarBackButtonHidden()
            .toolbar(.hidden, for: .navigationBar)
            .onAppear {
                guard !didPresent else { return }
                didPresent = true
                presented = true
            }
            .fullScreenCover(isPresented: $presented, onDismiss: { dismiss() }) {
                ModelDownloadModal(noteID: noteID, part: part, parakeetOnly: parakeetOnly, declineTurnsOff: declineTurnsOff)
            }
    }
}

private struct ModelDownloadModal: View {
    let noteID: UUID?
    let part: ModelPart?
    let parakeetOnly: Bool
    let declineTurnsOff: Bool
    @Environment(ProcessingStore.self) private var processing
    @Environment(\.modelRoot) private var modelRoot
    @Environment(\.dismiss) private var dismiss
    @State private var model: ModelDownloadModel?
    @State private var sources = false

    var body: some View {
        NavigationStack {
            Group {
                if let model, let plan = model.plan {
                    ModelDownloadContent(model: model, plan: plan)
                } else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity) }
            }
            .background(Color.paper)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(NoteCopy.close, systemImage: "xmark") {
                        if let model { model.close() } else { dismiss() }
                    }
                    .disabled(model?.busy == true)
                    .accessibilityIdentifier("closeModelDownload")
                }
            }
            .navigationDestination(isPresented: $sources) {
                LicenseDetailView(entry: .modelSources, models: modelRoot)
            }
        }
        .interactiveDismissDisabled(model?.busy == true)
        .task {
            guard model == nil else { return }
            guard let ports = parakeetOnly ? processing.parakeetDownload : processing.modelDownload else { dismiss(); return }
            let model = ModelDownloadModel(noteID: noteID, ports: ports, part: part, declineTurnsOff: declineTurnsOff)
            model.onEffect = { effect in
                switch effect {
                case .close: dismiss()
                case .openLicenses: sources = true
                }
            }
            self.model = model
            await model.load()
        }
        .onDisappear { model?.disappeared() }
    }
}

private struct ModelDownloadContent: View {
    let model: ModelDownloadModel
    let plan: ModelDownloadPlan
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @ScaledMetric(relativeTo: .largeTitle) private var titleSize: CGFloat = 30
    private var pad: Bool { sizeClass == .regular }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(pad ? SettingsPhase2Copy.offerTitleIpad : SettingsPhase2Copy.offerTitleIphone)
                        .font(.system(size: titleSize, weight: .bold)).foregroundStyle(Color.ink)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader).accessibilityIdentifier("modelDownloadTitle")
                    intro(total: plan.totalDownloadBytes).font(.body).foregroundStyle(Color.muted)
                    VStack(spacing: 0) {
                        ForEach(Array(plan.displayParts.enumerated()), id: \.element) { index, part in
                            if index > 0 { Divider().padding(.leading, 16) }
                            let layout = typeSize.isAccessibilitySize
                                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
                                : AnyLayout(HStackLayout(spacing: 12))
                            layout {
                                Text(part.label).font(.body).foregroundStyle(Color.ink)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                if let bytes = plan.displayBytes[part] {
                                    Text(SizeCopy.text(bytes, locale: locale))
                                        .font(.subheadline.monospacedDigit()).foregroundStyle(Color.muted)
                                }
                            }
                            .padding(.horizontal, 16).padding(.vertical, 14)
                            .accessibilityElement(children: .combine)
                        }
                    }.cardBackground(radius: 22)
                    if let language = model.speechLanguage {
                        // D59 (2): Apple Speech hears only the language set in Settings.
                        Text("Cassini recognises speech in \(name(of: language)). To transcribe another language, change it in Settings › Speech language.", tableName: "Transcription", comment: "On the consent screen of devices that use Apple’s speech models. %@ is the speech language’s name, e.g. Italian (Italy). ‘Settings › Speech language’ names the screen and the setting.")
                            .font(.subheadline).foregroundStyle(Color.muted)
                            .accessibilityIdentifier("speechLanguageLine")
                    }
                    Button(action: model.openSources) {
                        spaceAndSources
                            .font(.subheadline).foregroundStyle(Color.muted)
                            .multilineTextAlignment(.leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: HitTarget.minimum, alignment: .topLeading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(model.busy)
                    .accessibilityIdentifier("modelDownloadSources")
                    if typeSize.isAccessibilitySize { ModelDownloadActions(model: model) }
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8).padding(.bottom, 16)
            }
            .scrollBounceBehavior(.basedOnSize)
            if !typeSize.isAccessibilitySize { ModelDownloadActions(model: model) }
        }
        .padding(.horizontal, 20).padding(.bottom, 24)
        .readableWidth()
    }

    /// The space line with "Where do the files come from?" styled as an inline link at its end.
    private var spaceAndSources: Text {
        let space = SettingsPhase2Copy.offerSpace.replacingOccurrences(of: "{size}", with: SizeCopy.text(plan.requiredFreeBytes, locale: locale))
        var result = AttributedString(space + " ")
        var link = AttributedString(SettingsPhase2Copy.whereFromLink)
        link.foregroundColor = Color.accentInk
        link.font = .subheadline.weight(.medium)
        result += link
        return Text(result)
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
        var text = AttributedString((pad ? SettingsPhase2Copy.offerBodyIpad : SettingsPhase2Copy.offerBodyIphone)
            .replacingOccurrences(of: "{size}", with: size))
        if let range = text.range(of: size) {
            text[range].font = .body.weight(.bold)
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
                    if model.busy { ProgressView().tint(.onAccent) }
                }
            }
            .buttonStyle(PrimaryButtonStyle())
            .disabled(model.busy).accessibilityIdentifier("modelDownloadPrimary")
            Button(action: model.notNow) {
                Text(model.withNote ? SettingsPhase2Copy.offerNotNow : SettingsPhase2Copy.notNow)
            }
            .font(.body.weight(.medium)).tint(.ink)
            .frame(maxWidth: .infinity, minHeight: HitTarget.minimum)
            .disabled(model.busy).accessibilityIdentifier("modelDownloadNotNow")
        }
    }

    private var primaryLabel: Text {
        if model.identifiesSpeakers { Text("Download and identify speakers", tableName: "Transcription") }
        else if model.withNote { Text(SettingsPhase2Copy.offerDownload) }
        else { Text("Download", tableName: "Transcription") }
    }
}

extension ModelPart {
    /// The part's name on the model download screen.
    var label: String {
        switch self {
        case .speech: SettingsPhase2Copy.offerSpeech
        case .speakers: SettingsPhase2Copy.offerTellApart
        case .voices: SettingsPhase2Copy.offerRecognise
        }
    }
}
