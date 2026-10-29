import SwiftUI
import CassiniNotebook

/// What the transcript's paragraphs can ask for. One value for the whole list, so a paragraph view compares equal
/// when only the callbacks were made again.
struct TranscriptActions {
    var wordTap: (WordRef) -> Void = { _ in }
    var playTurn: (String) -> Void = { _ in }
    var nameSpeaker: (String) -> Void = { _ in }
    var editPassage: (UUID) -> Void = { _ in }
    var markMoment: (TimeInterval) -> Void = { _ in }
}

/// One paragraph of the transcript (Android `TurnHeader` and `TurnParagraph`): the speaker header, then the words.
///
/// Reading: the header is a 44 pt button that opens Name a speaker; each word is a link that plays from it; the word
/// being played is drawn inverted; search hits are highlighted, the current one in semibold. Draft: plain text in a
/// lighter colour, the words that may still change lighter again, and a header that opens Name a speaker while the job
/// lets the draft be named (else it is only a label).
///
/// VoiceOver reads the paragraph as one element whose default action plays it from its start, with no stop per word.
/// The view is `Equatable` over what it draws, so a new playback position redraws only the paragraphs that hold the
/// old and the new active word.
struct TurnView: View, Equatable {
    enum Style { case reading, draft }

    let turn: NoteTurn
    var activeIndex: Int?
    var matches: [Range<Int>] = []
    var currentMatch: Range<Int>?
    var style: Style = .reading
    /// The header opens Name a speaker (an attempt the transcript does not allow then shows why).
    var renamable = true
    var actions = TranscriptActions()
    /// Where the paragraph is, for auto-follow.
    var geometry: FollowGeometry?

    nonisolated static func == (a: TurnView, b: TurnView) -> Bool {
        a.turn == b.turn && a.activeIndex == b.activeIndex && a.matches == b.matches && a.currentMatch == b.currentMatch
            && a.style == b.style && a.renamable == b.renamable
    }

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.rendered(turn.id)
        #endif
        VStack(alignment: .leading, spacing: 2) {
            TurnHeader(turn: turn, button: renamable && turn.speakerID != nil) {
                if let id = turn.speakerID { actions.nameSpeaker(id) }
            }
            paragraph
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var placeholder: Bool { !turn.name.isNamed }

    @ViewBuilder private var paragraph: some View {
        let text = Text(attributed)
            .font(.system(.body, design: .serif)).lineSpacing(7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { frame in
                geometry?.frames[turn.id] = frame
            }
            .onDisappear { geometry?.frames[turn.id] = nil }
            // Assistive technologies see the plain paragraph: its word links would each be an element of their own.
            .accessibilityRepresentation { Text(verbatim: turn.text) }
            .accessibilityIdentifier("turn-\(turn.id)")
        switch style {
        case .reading:
            text
                .foregroundStyle(placeholder ? Color.muted : Color.ink)
                .tint(placeholder ? Color.muted : Color.ink)
                .environment(\.openURL, OpenURLAction { url in
                    guard let index = Self.wordIndex(url) else { return .systemAction }
                    actions.wordTap(WordRef(turnID: turn.id, index: index))
                    return .handled
                })
                .accessibilityAction { actions.playTurn(turn.id) }
                .accessibilityAction(named: NoteCopy.playFromStartOfTurn) { actions.playTurn(turn.id) }
                .accessibilityAction(named: NoteCopy.markThisMoment) { actions.markMoment(turn.start) }
                .accessibilityActions {
                    if let passage = turn.passages.first, turn.passages.count == 1 {
                        Button(NoteCopy.editPassage) { actions.editPassage(passage.id) }
                    }
                }
                .contextMenu { menu }
        case .draft:
            text.foregroundStyle(Color.muted)
        }
    }

    @ViewBuilder private var menu: some View {
        switch turn.passages.count {
        case 0: EmptyView()
        case 1: Button(NoteCopy.editPassage, systemImage: "pencil") { actions.editPassage(turn.passages[0].id) }
        default:
            Menu(NoteCopy.editPassage, systemImage: "pencil") {
                ForEach(turn.passages, id: \.id) { passage in
                    Button(NoteCopy.editPassage(at: passage.start)) { actions.editPassage(passage.id) }
                }
            }
        }
        Button(NoteCopy.markThisMoment, systemImage: "bookmark") { actions.markMoment(turn.start) }
        Button(NoteCopy.copyText, systemImage: "doc.on.doc") { UIPasteboard.general.string = turn.text }
    }

    // MARK: Text

    static let scheme = "cassini-word"

    static func wordIndex(_ url: URL) -> Int? {
        guard url.scheme == scheme else { return nil }
        return Int(url.absoluteString.dropFirst(scheme.count + 1))
    }

    /// The paragraph with its word links (reading), its unsettled words (draft), the active word and the search hits.
    private var attributed: AttributedString {
        var result = AttributedString(turn.text)
        let characters = result.characters
        func range(_ offsets: Range<Int>) -> Range<AttributedString.Index>? {
            guard offsets.lowerBound >= 0, offsets.upperBound <= characters.count else { return nil }
            let start = characters.index(characters.startIndex, offsetBy: offsets.lowerBound)
            return start..<characters.index(start, offsetBy: offsets.count)
        }
        switch style {
        case .reading:
            for index in turn.words.indices where index != activeIndex {
                if let word = range(turn.range(ofWord: index)) { result[word].link = URL(string: "\(Self.scheme):\(index)") }
            }
        case .draft:
            if let from = turn.unsettledFrom, turn.words.indices.contains(from),
               let rest = range(turn.offsets[from]..<turn.text.count) {
                result[rest].foregroundColor = Color.faint
            }
        }
        for match in matches {
            guard let hit = range(match) else { continue }
            result[hit].backgroundColor = Color.toneWarn.opacity(0.22)
            if match == currentMatch { result[hit].font = .system(.body, design: .serif, weight: .semibold) }
        }
        if style == .reading, let activeIndex, turn.words.indices.contains(activeIndex),
           let word = range(turn.range(ofWord: activeIndex)) {
            // The active word is drawn inverted. It carries no link, whose tint would win over its colour.
            result[word].foregroundColor = Color.paper
            result[word].backgroundColor = Color.ember
        }
        return result
    }
}

/// A paragraph's speaker line: an 8 pt dot, the name in the speaker's tint, the start time and the "auto" badge. As a
/// button it is at least 44 pt high and reads "Giulia, named automatically, at 11 minutes 41 seconds", hint "Name this
/// speaker".
private struct TurnHeader: View {
    let turn: NoteTurn
    let button: Bool
    let action: () -> Void

    var body: some View {
        let name = NoteCopy.speakerName(turn.name)
        let line = HStack(spacing: 6) {
            Circle().fill(turn.tint.color).frame(width: 8, height: 8)
            Text(name).font(.subheadline.weight(.semibold)).foregroundStyle(turn.tint.color).lineLimit(1)
            Text(TimeText.clock(turn.start)).font(.caption.monospacedDigit()).foregroundStyle(Color.muted)
            if turn.auto {
                Text(NoteCopy.auto).font(.caption2.weight(.semibold)).foregroundStyle(Color.muted)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .overlay(Capsule().stroke(Color.muted.opacity(0.5), lineWidth: 1))
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: HitTarget.minimum, alignment: .bottomLeading)
        .contentShape(Rectangle())
        let label = NoteCopy.turn(name, start: turn.start, auto: turn.auto)
        if button {
            Button(action: action) { line }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: label))
                .accessibilityHint(NoteCopy.nameThisSpeaker)
                .accessibilityAddTraits(.isButton)
                .accessibilityIdentifier("speakerHeader-\(turn.id)")
        } else {
            line.accessibilityElement(children: .ignore).accessibilityLabel(Text(verbatim: label))
        }
    }
}

#if DEBUG
/// Counts renders by key (a paragraph's id, or a part of the Note screen), for the tests that a playback tick redraws
/// only the paragraphs it concerns.
@MainActor enum RenderProbe {
    private(set) static var renders: [String: Int] = [:]
    static func rendered(_ id: String) { renders[id, default: 0] += 1 }
    static func reset() { renders = [:] }
}
#endif
