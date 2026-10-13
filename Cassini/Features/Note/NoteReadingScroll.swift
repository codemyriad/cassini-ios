import SwiftUI
import CassiniEngine
import CassiniNotebook

/// Every Note mode but processing: one scroll view with the header, the sections, the bookmarks, a stopped job's draft
/// and the reading transcript, with playback follow and search. Its scroll drives `NoteScreenModel.scrolled`; the
/// current search match is scrolled into view unless its line shows already (`PlaybackFollow.isInView`).
struct NoteReadingScroll: View {
    let note: Note
    let mode: NoteMode
    let transcript: NoteTranscript
    let subtitle: NoteSubtitle?
    let matches: [TranscriptMatch]
    let current: Int
    let savedDraft: [DraftWord]
    let model: NoteScreenModel
    let stores: NoteScreenStores
    let cache: TranscriptCache
    let actions: TranscriptActions
    let suggestion: (NoteTurn) -> AnyView?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var geometry = FollowGeometry()
    @State private var scrollPosition = ScrollPosition()

    /// About one line of the transcript's body text.
    private static let lineHeight: CGFloat = 24

    private var currentMatch: TranscriptMatch? { matches.indices.contains(current) ? matches[current] : nil }

    var body: some View {
        @Bindable var model = model
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    NoteHeader(note: note, subtitle: subtitle)
                    ForEach(mode.sections, id: \.self) {
                        NoteSectionView(section: $0, note: note, mode: mode, model: model, stores: stores)
                    }
                    if mode.hasPlayer, !note.bookmarks.isEmpty {
                        BookmarksSection(note: note, isExpanded: $model.showBookmarks) { model.seek($0, stores) }
                    }
                    if mode.showsDraft, !savedDraft.isEmpty {
                        DraftSection(transcript: cache.saved(savedDraft), changing: false)
                    }
                    if note.saysNoSpeech(in: mode) {
                        NoSpeechState()
                    } else if !transcript.isEmpty {
                        ReadingTranscript(noteID: note.id, transcript: transcript, hits: TranscriptHits(matches, current: current),
                                          renamable: true, following: model.screen.follow.following,
                                          actions: actions, geometry: geometry, proxy: proxy,
                                          position: $scrollPosition, suggestion: suggestion)
                    }
                }
                .padding(Spacing.gutter).readableWidth()
            }
            .scrollPosition($scrollPosition)
            .onScrollGeometryChange(for: ScrollMetrics.self) { ScrollMetrics($0) } action: { _, metrics in
                geometry.offset = metrics.offset; geometry.top = metrics.top
                geometry.height = metrics.height; geometry.maxOffset = metrics.maxOffset
            }
            .onScrollPhaseChange { _, phase in
                let playback = stores.playback
                model.scrolled(PlaybackFollow.Scrolling(phase), playing: playback.owns(note.id) && playback.state.isPlaying)
            }
            // Also on the first value: a search the Library opened scrolls to its first match.
            .task(id: currentMatch) {
                guard let currentMatch else { return }
                await Task.yield()
                reveal(currentMatch, proxy: proxy)
            }
        }
    }

    /// Scrolls the current search match into the middle of the pane, unless its line is in view already; without
    /// animation under Reduce Motion.
    private func reveal(_ match: TranscriptMatch, proxy: ScrollViewProxy) {
        if let turn = transcript.turn(match.turnID), let frame = geometry.frames[match.turnID] {
            let fraction = turn.text.isEmpty ? 0 : Double(match.range.lowerBound) / Double(turn.text.count)
            let lineY = frame.minY - geometry.top + frame.height * fraction
            if PlaybackFollow.isInView(lineY: lineY, lineHeight: Self.lineHeight, height: geometry.height) { return }
        }
        withAnimation(reduceMotion ? nil : .default) { proxy.scrollTo(match.turnID, anchor: .center) }
    }
}

/// What auto-follow needs to know about the scroll view: its offset, the top inset (the search bar and the
/// navigation bar), the height between the insets, and the largest offset.
private struct ScrollMetrics: Equatable {
    var offset: CGFloat
    var top: CGFloat
    var height: CGFloat
    var maxOffset: CGFloat

    init(_ geometry: ScrollGeometry) {
        let insets = geometry.contentInsets
        offset = geometry.contentOffset.y
        top = insets.top
        height = max(0, geometry.containerSize.height - insets.top - insets.bottom)
        maxOffset = max(-insets.top, geometry.contentSize.height + insets.bottom - geometry.containerSize.height)
    }
}
