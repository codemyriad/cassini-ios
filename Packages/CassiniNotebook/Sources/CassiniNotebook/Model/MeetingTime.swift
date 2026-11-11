import Foundation
import CassiniCore

/// The meeting start, distinct from file creation/sealing and the catalogue sorting fallback (D95).
/// A wall-clock label without a zone is displayed exactly as stored, never converted to an instant.
public enum MeetingTime: Hashable, Codable, Sendable {
    case instant(Date)
    case local(String)
    case unknown

    public var instant: Date? { if case .instant(let date) = self { date } else { nil } }
    public var localText: String? { if case .local(let text) = self { text } else { nil } }

    public static func read(_ document: CassiniDocument) -> MeetingTime {
        let meeting = document.manifest?["meeting"]?.object
        if let text = meeting?["recordedAtUtc"]?.string, text.hasSuffix("Z"), let date = parse(text) {
            return .instant(date)
        }
        let created = meeting?["createdAtUtc"]?.string.flatMap(parse)
        // DATE must explicitly carry a zone; an offset-less label cannot establish an instant.
        for comment in document.comments {
            guard let equal = comment.firstIndex(of: "="), comment[..<equal].uppercased() == "DATE" else { continue }
            let text = String(comment[comment.index(after: equal)...])
            guard text.range(of: #"(?:Z|[+-][0-9]{2}:[0-9]{2})$"#, options: .regularExpression) != nil,
                  let date = parse(text), date != created else { continue }
            return .instant(date)
        }
        if let text = meeting?["recordedAtLocal"]?.string, !text.isEmpty { return .local(text) }
        return .unknown
    }

    static func parse(_ text: String) -> Date? {
        (try? Date(text, strategy: .iso8601))
            ?? (try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)))
    }
}
