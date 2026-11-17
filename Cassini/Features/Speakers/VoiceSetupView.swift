import SwiftUI
import UIKit
import CassiniEngine

/// D103's phone question; the containing note owns the one-time answer and dismissal.
struct VoicesQuestionSheet: View {
    let answer: (Bool) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 24
    @ScaledMetric(relativeTo: .subheadline) private var privacySize: CGFloat = 14
    @State private var contentHeight: CGFloat = 580
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Image(systemName: "person.2").font(.system(size: 30)).foregroundStyle(Color.accentInk)
                    .accessibilityHidden(true)
                VoicesQuestionHeading(text: SettingsPhase2Copy.voicesTitle, size: titleSize)
                    .fixedSize(horizontal: false, vertical: true)
                Text(SettingsPhase2Copy.voicesBody).font(.callout).foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "lock").accessibilityHidden(true)
                    Text(SettingsPhase2Copy.voicesPrivacy).fixedSize(horizontal: false, vertical: true)
                }.font(.system(size: privacySize)).foregroundStyle(Color.muted)
                VStack(spacing: 10) {
                    Button(SettingsPhase2Copy.voicesEnable) { answer(true) }
                        .buttonStyle(PrimaryButtonStyle()).accessibilityIdentifier("voicesQuestionYes")
                    Button(SettingsPhase2Copy.notNow) { answer(false) }
                        .font(.body.weight(.semibold)).foregroundStyle(Color.ink)
                        .padding(.vertical, 14).frame(maxWidth: .infinity, minHeight: 52)
                        .background(Color.neutralTint, in: Capsule()).accessibilityIdentifier("voicesQuestionNotNow")
                }
                VStack(spacing: 4) {
                    Text(SettingsPhase2Copy.voicesKindness)
                    Text(SettingsPhase2Copy.voicesChangeLater).accessibilityIdentifier("voicesQuestionChangeLater")
                }.font(.footnote).foregroundStyle(Color.muted).multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 26)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 + 24 }
        }
        .accessibilityIdentifier("voicesQuestionScroll")
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents(typeSize.isAccessibilitySize ? [.large] : [.height(contentHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(34)
        .presentationBackground(Color.raised)
    }
}

/// UIKit measures the same multiline heading it exposes to accessibility, including French at AX5.
/// Its explicit width and intrinsic height keep long translations intact at the largest text size.
private struct VoicesQuestionHeading: UIViewRepresentable {
    let text: String
    let size: CGFloat
    func makeUIView(context: Context) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 0
        label.lineBreakMode = .byWordWrapping
        label.accessibilityTraits = [.header, .staticText]
        label.accessibilityIdentifier = "voicesQuestionTitle"
        label.setContentCompressionResistancePriority(.required, for: .vertical)
        return label
    }
    func updateUIView(_ label: UILabel, context: Context) {
        label.text = text
        label.font = .systemFont(ofSize: size, weight: .bold)
        label.textColor = UIColor(Color.ink)
    }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UILabel, context: Context) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let measured = uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
        return CGSize(width: width, height: ceil(measured.height))
    }
}

struct VoiceEnrollmentView: View {
    @Environment(VoiceEnrollmentAdapter.self) private var enrollment
    @Environment(VoicesStore.self) private var voices
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(Wave6Copy.voicesEnrollInstructions)
                    TextField(SpeakersCopy.nameField, text: $name).textInputAutocapitalization(.words)
                }
                Section {
                    Text(Wave6Copy.voicesEnrollTestPhrase)
                    Text(Wave6Copy.voicesEnrollFromTranscriptHint).font(.footnote).foregroundStyle(Color.muted)
                } header: { Text(Wave6Copy.voicesEnrollTestPhraseLabel) }
                Section {
                    Button(enrollment.recording ? Wave6Copy.commonStop : Wave6Copy.voicesEnrollRecord) {
                        Task {
                            do {
                                if enrollment.recording { try await enrollment.finish() }
                                else { try await enrollment.start() }
                            } catch { errors.present(error.localizedDescription) }
                        }
                    }
                    .disabled(enrollment.busy)
                    if enrollment.recording { Text(Wave6Copy.voicesEnrollRecording) }
                    if let failure = enrollment.failure { Text(failure).foregroundStyle(Color.toneError) }
                    if enrollment.tooShort { Text(Wave6Copy.voicesEnrollTooShort).foregroundStyle(Color.toneWarn) }
                    if enrollment.print != nil { Text(Wave6Copy.voicesEnrollReady) }
                    Button(Wave6Copy.voicesEnrollSave) {
                        Task {
                            do {
                                try await enrollment.save(name: name, voices: voices)
                                dismiss()
                            } catch { errors.present(error.localizedDescription) }
                        }
                    }
                    .disabled(enrollment.print == nil || enrollment.busy || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .navigationTitle(Wave6Copy.voicesEnrollTitle)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(Wave6Copy.commonCancel) { dismiss() }.disabled(enrollment.busy) } }
            .interactiveDismissDisabled(enrollment.busy)
            .onDisappear { Task { await enrollment.cancel() } }
        }
    }
}
