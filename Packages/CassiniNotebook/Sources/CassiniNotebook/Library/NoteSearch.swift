import Foundation

extension Note {
    public func matches(_ query: String) -> Bool {
        let haystack = (title + " " + text + " " + bookmarks.map(\.label).joined(separator: " "))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let terms = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .split(whereSeparator: \.isWhitespace)
        return terms.allSatisfy { haystack.contains($0) }
    }

    public func preview(matching query: String) -> String {
        let body = text
        guard let term = query.split(whereSeparator: \.isWhitespace).first,
              let match = body.range(of: String(term), options: [.caseInsensitive, .diacriticInsensitive]) else {
            return String(body.prefix(180))
        }
        let start = body.index(match.lowerBound, offsetBy: -45, limitedBy: body.startIndex) ?? body.startIndex
        return (start == body.startIndex ? "" : "…") + String(body[start...].prefix(180))
    }
}
