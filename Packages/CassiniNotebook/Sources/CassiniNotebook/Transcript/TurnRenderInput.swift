import Foundation

/// The value compared by a paragraph view. Playback is reduced to this paragraph's word index;
/// callbacks and scroll geometry belong to the host and do not invalidate its drawing.
public struct TurnRenderInput: Equatable, Sendable {
    public enum Style: Equatable, Sendable { case reading, draft }

    public var turn: NoteTurn
    public var activeIndex: Int?
    public var matches: [Range<Int>]
    public var currentMatch: Range<Int>?
    public var style: Style
    public var renamable: Bool

    public init(turn: NoteTurn, activeWord: WordRef? = nil, matches: [Range<Int>] = [],
                currentMatch: Range<Int>? = nil, style: Style = .reading, renamable: Bool = true) {
        self.turn = turn
        self.activeIndex = activeWord?.turnID == turn.id ? activeWord?.index : nil
        self.matches = matches
        self.currentMatch = currentMatch
        self.style = style
        self.renamable = renamable
    }
}
