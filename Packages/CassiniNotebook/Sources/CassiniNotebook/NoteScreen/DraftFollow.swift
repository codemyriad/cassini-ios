/// Auto-follow of the running job's draft (Android `DraftList`): new text scrolls the end of the draft into view while
/// it sticks to the end. A scroll that ends above the end stops it, and a scroll back to the end starts it again.
/// Opening the screen does not scroll. The progress card stays fixed above the draft while at least `minDraftSpace`
/// is left for the draft below it (about six draft lines); otherwise card and draft scroll together.
public struct DraftFollow: Hashable, Sendable {
    /// The space the draft keeps below a fixed card, in points (Android's 160 dp).
    public static let minDraftSpace: Double = 160

    /// New text scrolls to the end.
    public private(set) var sticks = true

    public init(sticks: Bool = true) { self.sticks = sticks }

    /// A scroll by the user ended, at the end of the draft or above it.
    public mutating func scrollEnded(atEnd: Bool) { sticks = atEnd }

    /// Whether the card stays fixed above the draft, in an `area` that tall with a card `card` tall (margins included).
    /// Before the first measurement (`area` 0) it is fixed.
    public static func pinsCard(area: Double, card: Double) -> Bool {
        area <= 0 || area - card >= minDraftSpace
    }

    /// Whether a scroll view whose content is `contentHeight` tall shows its end at `offset`, `visibleHeight` of it in
    /// view; content that fits is at its end.
    public static func isAtEnd(offset: Double, visibleHeight: Double, contentHeight: Double) -> Bool {
        offset + visibleHeight >= contentHeight - endTolerance
    }

    /// Points from the end that still count as the end: a fling rarely stops on the last point.
    static let endTolerance: Double = 8
}
