import SwiftUI
import CassiniEngine

/// Imports have no persisted meeting until the storage transaction succeeds.
struct ImportCardsView: View {
    @Environment(ImportStore.self) private var imports
    var body: some View {
        ForEach(imports.tracker.cards) { card in
            ImportCardView(card: card, retry: { imports.retry(card) }, dismiss: { imports.tracker.dismissCard(card.id) })
        }
    }
}

struct ImportCardView: View {
    let card: ImportTracker.Card
    let retry: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.displayName).font(.system(size: 17, weight: .semibold)).foregroundStyle(Color.ink)
            HStack {
                StatusPill(text: StatusBadgeCopy.template(card.failure == nil ? "states.badge.importing" : "states.badge.needsAttention"),
                           glyph: card.failure == nil ? .spinner : .symbol("exclamationmark.circle"),
                           ink: card.failure == nil ? .ink2 : .warnInk,
                           fill: card.failure == nil ? Color.ink.opacity(0.1) : .warnTint)
                Spacer(minLength: 0)
                if card.failure != nil {
                    if card.source != nil {
                        Button(LibraryPhase1Copy.tryAgain, action: retry).frame(minHeight: HitTarget.minimum).accessibilityIdentifier("retryImport")
                    }
                    Button(LibraryPhase1Copy.close, systemImage: "xmark", action: dismiss)
                        .labelStyle(.iconOnly).frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum).accessibilityIdentifier("dismissImport")
                }
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.ink)
        }
        .padding(Spacing.card).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.cardRest, in: RoundedRectangle(cornerRadius: Radius.card))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier(card.failure == nil ? "importingCard" : "failedImportCard")
    }
}
