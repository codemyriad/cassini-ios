import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The Note screen for draft-bearing modes (`Processing`, `Paused`, `Failed` without a document, and `Queued` over an
/// unfinished checkpoint, matching Android `DraftList`): the top (the header and the status strip, Queued card or
/// banner) stays fixed above a scrolling list of the draft while the draft keeps `DraftFollow.minDraftSpace` below it;
/// otherwise (a short window, a large text size) the top scrolls with the draft. Sharing one scroll view across these
/// modes keeps a held-away scroll position and `DraftFollow` state intact across Stop, Resume and opening Details.
struct ProcessingBody<Top: View, Banners: View>: View {
    let note: Note
    let isProcessing: Bool
    let model: NoteScreenModel
    let cache: TranscriptCache
    @ViewBuilder let top: () -> Top
    @ViewBuilder let banners: () -> Banners
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var follow = DraftFollow()
    @State private var position = ScrollPosition(edge: .top)
    @State private var areaHeight: CGFloat = 0
    @State private var topHeight: CGFloat = 0
    @State private var draftScrolled = false

    var body: some View {
        @Bindable var model = model
        // The fixed top takes its height, the gutter above it and the gap below it.
        let pinned = DraftFollow.pinsCard(area: areaHeight, card: topHeight + Spacing.gutter + Spacing.tight)
        VStack(spacing: 0) {
            if pinned {
                topContent
                    .padding(.horizontal, Spacing.gutter).padding(.top, Spacing.gutter).padding(.bottom, Spacing.tight)
                    .readableWidth()
                if isProcessing, draftScrolled {
                    Rectangle().fill(Color.line).frame(height: 1)
                        .accessibilityIdentifier("transcribingScrolledDivider")
                        .accessibilityHidden(true)
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.section) {
                        if !pinned { topContent }
                        banners()
                        if !isProcessing, !note.bookmarks.isEmpty {
                            BookmarksSection(note: note, isExpanded: $model.showBookmarks, model: model)
                        }
                        RunningDraft(model: model, cache: cache)
                    }
                    .padding(.horizontal, Spacing.gutter).padding(.top, pinned ? Spacing.tight : Spacing.gutter)
                    .padding(.bottom, Spacing.gutter)
                    // The end of the list, for the scroll below iOS 26 only; an overlay, so the layout does not change.
                    .overlay(alignment: .bottom) {
                        if #available(iOS 26.0, *) {} else {
                            Color.canvasClear.frame(height: 1).id(Self.end).accessibilityHidden(true)
                        }
                    }
                    .readableWidth()
                }
                .accessibilityIdentifier("draftScroll")
                .scrollPosition($position)
                .onScrollGeometryChange(for: Bool.self) {
                    $0.contentOffset.y + $0.contentInsets.top > 0.5
                } action: { _, scrolled in
                    draftScrolled = scrolled
                }
                // Any draft change that makes the list taller (more words, or tentative words settling into longer
                // text). Initial mount (old == 0) does not scroll on opening.
                .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height } action: { old, new in
                    if isProcessing, old > 0, new > old { contentGrew(proxy) }
                }
                .onScrollPhaseChange { old, new, context in
                    // A scroll the user made starts and ends; one Cassini made (to the end) leaves following as it was.
                    // While the user's scroll runs, new text does not scroll, so it never turns into Cassini's scroll.
                    if new == .interacting { follow.scrollBegan() }
                    if new == .idle, old == .interacting || old == .decelerating {
                        // Decide from this scroll-end event, including its final geometry.
                        let geometry = context.geometry
                        follow.scrollEnded(atEnd: DraftFollow.isAtEnd(
                            offset: geometry.contentOffset.y + geometry.contentInsets.top,
                            visibleHeight: geometry.containerSize.height - geometry.contentInsets.top
                                - geometry.contentInsets.bottom,
                            contentHeight: geometry.contentSize.height))
                    }
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { areaHeight = $0 }
        #if DEBUG
        .overlay(alignment: .bottomLeading) {
            UITestStateMarker(identifier: "draftFollow",
                              value: "scrolling=\(follow.userScrolling),following=\(follow.followsNewText)")
        }
        #endif
    }

    /// The header and the status/card/banner, measured so the fixed layout knows what it leaves for the draft.
    private var topContent: some View {
        VStack(alignment: .leading, spacing: Spacing.row) { top() }
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
