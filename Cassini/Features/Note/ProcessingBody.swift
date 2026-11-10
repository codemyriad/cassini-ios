import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Note screen while its job runs (Android `DraftList`): the top (the header and the progress card) stays fixed
/// above a scrolling list of the banners and the draft while the draft keeps `DraftFollow.minDraftSpace` below it;
/// otherwise (a short window, a large text size) the top scrolls with the draft. New draft text scrolls the end of the
/// draft into view while it sticks to the end (`DraftFollow`); only the list scrolls, so a fixed card stays in view.
struct ProcessingBody<Top: View, Banners: View>: View {
    let model: NoteScreenModel
    let cache: TranscriptCache
    @ViewBuilder let top: () -> Top
    @ViewBuilder let banners: () -> Banners
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var follow = DraftFollow()
    @State private var position = ScrollPosition(edge: .top)
    @State private var atEnd = true
    @State private var areaHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 0

    var body: some View {
        // The fixed top takes its height, the gutter above it and the gap below it.
        let pinned = DraftFollow.pinsCard(area: areaHeight, card: topHeight + Spacing.gutter + Spacing.tight)
        VStack(spacing: 0) {
            if pinned {
                topContent
                    .padding(.horizontal, Spacing.gutter).padding(.top, Spacing.gutter).padding(.bottom, Spacing.tight)
                    .readableWidth()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.section) {
                        if !pinned { topContent }
                        banners()
                        RunningDraft(model: model, cache: cache)
                    }
                    .padding(.horizontal, Spacing.gutter).padding(.top, pinned ? 0 : Spacing.gutter)
                    .padding(.bottom, Spacing.gutter)
                    // The end of the list, for the scroll below iOS 26; an overlay, so the layout does not change.
                    .overlay(alignment: .bottom) { Color.clear.frame(height: 1).id(Self.end).accessibilityHidden(true) }
                    .readableWidth()
                }
                .scrollPosition($position)
                .onScrollGeometryChange(for: Bool.self) { geometry in
                    DraftFollow.isAtEnd(offset: geometry.contentOffset.y + geometry.contentInsets.top,
                                        visibleHeight: geometry.containerSize.height - geometry.contentInsets.top
                                            - geometry.contentInsets.bottom,
                                        contentHeight: geometry.contentSize.height)
                } action: { _, end in atEnd = end }
                // Any draft change that makes the list taller (more words, or tentative words settling into longer
                // text).
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                    if new > old { contentGrew(proxy) }
                }
                .onScrollPhaseChange { old, new in
                    // A scroll the user made starts and ends; one Cassini made (to the end) leaves following as it was.
                    // While the user's scroll runs, new text does not scroll, so it never turns into Cassini's scroll.
                    if new == .interacting { follow.scrollBegan() }
                    if new == .idle, old == .interacting || old == .decelerating { follow.scrollEnded(atEnd: atEnd) }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { areaHeight = $0 }
    }

    /// The header and the card, measured so the fixed layout knows what it leaves for the draft.
    private var topContent: some View {
        VStack(alignment: .leading, spacing: Spacing.section) { top() }
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { topHeight = $0 }
    }

    private static var end: String { "draftListEnd" }

    /// Taller content: to the end, while the draft sticks to it and the user is not scrolling.
    /// Below iOS 26 the position's `scrollTo(edge: .bottom)` does not follow the growth: on iOS 18.2 the list stayed at
    /// its top while the draft ran off the screen (likely because a position that already holds the bottom edge, set
    /// while the draft still fit, does not change). The reader's scroll to the end of the list acts on every call.
    private func contentGrew(_ proxy: ScrollViewProxy) {
        guard follow.followsNewText else { return }
        withAnimation(reduceMotion ? nil : .default) {
            if #available(iOS 26.0, *) {
                position.scrollTo(edge: .bottom)
            } else {
                proxy.scrollTo(Self.end, anchor: .bottom)
            }
        }
    }
}
