import SwiftUI
import CassiniEngine

/// Shared D78 copy and actions for Settings and the first completed Whistle transcription.
struct ParakeetSuggestionView: View {
    let store: SpeechModelsStore
    let placement: ParakeetSuggestionPlacement
    @Environment(\.locale) private var locale
    #if DEBUG
    @Environment(\.marksUITestLayout) private var marksForUITests
    #endif

    var body: some View {
        if store.shows(placement) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Get better transcripts with Parakeet Ultra", tableName: "Settings").font(.headline)
                let size = SizeCopy.text(store.policy.downloadPlan.totalBytes, locale: locale)
                Text("Whistle is built in so you can start right away. Parakeet Ultra is more accurate. It’s a \(size) download.", tableName: "Settings")
                    .font(.subheadline).foregroundStyle(Color.muted)
                HStack {
                    Button { store.requestDownload() } label: { Text("Download", tableName: "Transcription") }
                        .accessibilityIdentifier("downloadParakeetSuggestion")
                    Button { store.dismissSuggestion() } label: { Text("Not now", tableName: "Settings") }
                        .accessibilityIdentifier("dismissParakeetSuggestion")
                }.buttonStyle(.bordered)
            }
            .padding(.vertical, 6)
            #if DEBUG
            // UI tests only: the first showing after Whistle has been recorded in the preferences, so a test can end
            // the process after it rather than right after the card appears (`.task` records it a moment later).
            .overlay(alignment: .bottomLeading) {
                if marksForUITests, placement == .afterWhistle, store.suggestion.afterWhistlePresented {
                    Text(verbatim: " ").font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("parakeetSuggestionRecorded")
                }
            }
            #endif
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("parakeetSuggestion")
            .task { if placement == .afterWhistle { store.markAfterWhistleShown() } }
            .onDisappear { if placement == .afterWhistle { store.hideAfterWhistle() } }
        }
        if store.promotionVisible {
            HStack {
                Text("New meetings now use Parakeet Ultra.", tableName: "Settings")
                Spacer(minLength: 8)
                Button { store.dismissPromotion() } label: { Image(systemName: "xmark") }
                    .accessibilityLabel(NoteCopy.close)
            }
            .accessibilityIdentifier("parakeetNowDefault")
            .task { store.markPromotionShown() }
            .onDisappear { store.dismissPromotion() }
        }
    }
}

struct SpeechModelChoiceRow: View {
    let store: SpeechModelsStore

    var body: some View {
        if store.policy.whistleAvailable {
            Picker(selection: Binding(get: store.selectedRecognizer, set: store.choose)) {
                Text(verbatim: "Whistle").tag(SpeechRecognizer.whistle)
                if store.policy.parakeetInstallation == .verified && store.parakeetCapable {
                    Text(verbatim: "Parakeet Ultra").tag(SpeechRecognizer.parakeet)
                        .disabled(!store.policy.parakeetRunnable)
                }
            } label: {
                Text("Speech recognition", tableName: "Settings")
            }
            .accessibilityIdentifier("speechModelChoice")
        }
    }
}
