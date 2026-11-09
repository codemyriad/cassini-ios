import Foundation

extension NoteTurn {
    /// The actual reading links, including a chip's label and closing parenthesis. Keep its active atom link-free:
    /// the UI paints that word last, and a link's tint must never override the active foreground.
    public func linkedText(activeWord: Int? = nil, scheme: String = "cassini-word") -> AttributedString {
        var result = AttributedString(text)
        let characters = result.characters
        func link(_ offsets: Range<Int>, to index: Int) {
            guard offsets.lowerBound >= 0, offsets.upperBound <= characters.count, !offsets.isEmpty else { return }
            let start = characters.index(characters.startIndex, offsetBy: offsets.lowerBound)
            let end = characters.index(start, offsetBy: offsets.count)
            result[start..<end].link = URL(string: "\(scheme):\(index)")
        }
        for index in words.indices where index != activeWord { link(range(ofWord: index), to: index) }
        for chip in interjections {
            let first = chip.wordRange.lowerBound, last = chip.wordRange.upperBound - 1
            link(chip.textRange.lowerBound..<offsets[first], to: first)
            link(range(ofWord: last).upperBound..<chip.textRange.upperBound, to: last)
        }
        return result
    }
}
