/// The title belongs in the header while any of it remains below the bars covering the reading viewport.
/// Scroll offsets and the measured title bottom share content coordinates; the inset includes Find when open.
public struct MeetingTitleVisibility: Equatable, Sendable {
    private var titleBottom: Double?
    private var offset: Double = 0
    private var topInset: Double = 0
    private var resolved = false
    public private(set) var isVisible = true

    public init() {}

    /// Publishes the first measured decision, then only visibility transitions. A recreated reader can
    /// synchronize its parent without continually redrawing the Note screen during scrolling.
    public mutating func measured(bottom: Double) -> Bool? {
        titleBottom = bottom
        return transition()
    }

    /// Insets can change without a scroll: opening Find must reevaluate the same content position too.
    public mutating func scrolled(offset: Double, topInset: Double) -> Bool? {
        self.offset = offset
        self.topInset = topInset
        return transition()
    }

    private mutating func transition() -> Bool? {
        guard let titleBottom else { return nil }
        let visible = offset + topInset < titleBottom
        guard !resolved || visible != isVisible else { return nil }
        resolved = true
        isVisible = visible
        return visible
    }
}
