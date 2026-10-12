import SwiftUI
import CassiniEngine
import CassiniNotebook

/// "Transcribe on this device": consent for downloading the models a note, or a standalone download, needs.
struct ModelDownloadView: View {
    let noteID: UUID?
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
            guard model == nil, let ports = processing.modelDownload else { return }
            let model = ModelDownloadModel(noteID: noteID, ports: ports)
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
    let plan: ModelPlan

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    OrbitMark(size: 56)
                    Text("Transcribe on this device", tableName: "Transcription")
                        .font(.system(.largeTitle, design: .serif)).foregroundStyle(Color.ink)
                        .accessibilityAddTraits(.isHeader)
                    Text("Cassini needs a one-time download. After that, recognising words and telling voices apart happen on this device, even offline. Your audio stays here.", tableName: "Transcription")
                        .font(.title3).foregroundStyle(Color.muted)
                    VStack(spacing: 0) {
                        ForEach(Array(plan.missing.enumerated()), id: \.element) { index, part in
                            if index > 0 { Divider().padding(.leading, 16) }
                            Text(part.label).font(.body).foregroundStyle(Color.ink)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 16).padding(.vertical, 14)
                        }
                    }.cardBackground(radius: Radius.control)
                    Text("Needs about \(plan.requiredFreeBytes.formatted(.byteCount(style: .file))) free while installing. Each file is checked before it is used.", tableName: "Transcription")
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
        .frame(maxWidth: ReadableWidth.note).frame(maxWidth: .infinity)
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
                    Text(model.withNote ? "Download and transcribe" : "Download", tableName: "Transcription")
                        .opacity(model.busy ? 0 : 1)
                    if model.busy { ProgressView().tint(.white) }
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
