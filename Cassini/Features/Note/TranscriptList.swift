import SwiftUI
import CassiniNotebook

/// Where the paragraphs on screen are and how the transcript is scrolled, for auto-follow. A plain reference, not
/// observed state: only the follow step reads it, so a scroll never redraws the transcript.
@MainActor final class FollowGeometry {
    /// Each paragraph's frame in the scroll view's visible coordinates, while it is laid out.
    var frames: [String: CGRect] = [:]
    /// The scroll view's content offset, and its top inset (the bars over the content).
    var offset: CGFloat = 0
    var top: CGFloat = 0
    /// The height between the insets: the transcript's pane.
    var height: CGFloat = 0
    var maxOffset: CGFloat = 0
}

/// The search hits of a transcript, by paragraph, and the current one.
struct TranscriptHits: Equatable {
    var ranges: [String: [Range<Int>]] = [:]
    var current: TranscriptMatch?

    init(_ matches: [TranscriptMatch] = [], current index: Int = 0) {
        for match in matches { ranges[match.turnID, default: []].append(match.range) }
        current = matches.indices.contains(index) ? matches[index] : nil
    }
}

/// The transcript, paragraph by paragraph, in a lazy stack: only the paragraphs near the screen are made, and each one
/// is drawn again only when what it shows changes: `TurnView` is `Equatable`, which SwiftUI uses to diff a view that
/// holds closures (not `.equatable()`, whose rows iOS 27 redraws without comparing them). `activeWord` is the only
/// input that moves with playback. `suggestion` puts a card above a paragraph, e.g. "Is this Luca?".
struct TranscriptList: View {
    let transcript: NoteTranscript
    var activeWord: WordRef?
    var hits = TranscriptHits()
    var style: TurnView.Style = .reading
    var renamable = true
    var actions = TranscriptActions()
    var geometry: FollowGeometry?
    var suggestion: (NoteTurn) -> AnyView? = { _ in nil }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 14) {
            ForEach(transcript.turns) { turn in
                if let card = suggestion(turn) { card }
                TurnView(input: TurnRenderInput(turn: turn, activeWord: activeWord,
                                               matches: hits.ranges[turn.id] ?? [],
                                               currentMatch: hits.current?.turnID == turn.id ? hits.current?.range : nil,
                                               style: style, renamable: renamable),
                         actions: actions, geometry: geometry)
                    .id(turn.id)
            }
        }
    }
}

/// The reading transcript with the active word: the one view that reads the playback position, so a tick redraws
/// this list's diff and nothing above it. While following, a new active word whose line left the top 70 % of the
/// pane scrolls it to 30 %, without animation under Reduce Motion.
struct ReadingTranscript: View {
    let noteID: UUID
    let transcript: NoteTranscript
    let hits: TranscriptHits
    let renamable: Bool
    let following: Bool
    let actions: TranscriptActions
    let geometry: FollowGeometry
    let proxy: ScrollViewProxy
    @Binding var position: ScrollPosition
    let suggestion: (NoteTurn) -> AnyView?
    @Environment(PlaybackStore.self) private var playback
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        // The note's own player marks the word, also while paused; another note's player, or a failed one, marks none.
        let active = playback.owns(noteID) ? transcript.activeWord(at: playback.state.position) : nil
        TranscriptList(transcript: transcript, activeWord: active, hits: hits, renamable: renamable, actions: actions,
                       geometry: geometry, suggestion: suggestion)
            .onChange(of: active) { _, word in
                guard following, playback.state.isPlaying, let word else { return }
                follow(word)
            }
    }

    private func follow(_ word: WordRef) {
        let animation: Animation? = reduceMotion ? nil : .easeInOut(duration: 0.25)
        guard let turn = transcript.turn(word.turnID), let frame = geometry.frames[word.turnID], geometry.height > 0 else {
            withAnimation(animation) { proxy.scrollTo(word.turnID, anchor: UnitPoint(x: 0.5, y: PlaybackFollow.anchor)) }
            return
        }
        // The word's line, from where its first character sits in the paragraph.
        let fraction = turn.text.isEmpty ? 0 : Double(turn.offsets[word.index]) / Double(turn.text.count)
        let lineY = frame.minY - geometry.top + frame.height * fraction
        guard let delta = PlaybackFollow.scroll(lineY: lineY, height: geometry.height) else { return }
        let target = min(max(geometry.offset + delta, -geometry.top), geometry.maxOffset)
        withAnimation(animation) { position.scrollTo(y: target) }
    }
}

/// "Follow playback", 16 pt above the player while the note plays and auto-follow is paused.
struct FollowChip: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(NoteCopy.followPlayback, systemImage: "text.line.first.and.arrowtriangle.forward")
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 16).frame(minHeight: HitTarget.minimum)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.paper)
        .background(Color.ink, in: Capsule())
        .shadow(color: .compatibilityBlack.opacity(0.15), radius: 8, y: 2)
        .padding(.bottom, 16)
        .accessibilityIdentifier("followPlayback")
    }
}

/// "No speech": a transcript that was read and has no words.
struct NoSpeechState: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "text.bubble").font(.system(size: 30, weight: .light)).foregroundStyle(Color.ember)
                .accessibilityHidden(true)
            Text(NoteCopy.noSpeechTitle).font(.system(.title2, design: .serif))
            Text(NoteCopy.noSpeechBody).font(.subheadline).foregroundStyle(Color.muted).multilineTextAlignment(.center)
        }
        .padding(.vertical, 40).frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("noSpeech")
    }
}
