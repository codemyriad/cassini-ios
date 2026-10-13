import Foundation

/// A marked moment of a note (an iOS extra).
public struct Bookmark: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var time: Double
    /// The words the user gave the moment; nil for a moment marked without any, which the screen names in the
    /// reader's language ("Moment at 1:05").
    public var label: String?
    public init(id: UUID = UUID(), time: Double, label: String? = nil) {
        self.id = id; self.time = max(0, time); self.label = label
    }
}

extension Bookmark: Codable {
    private enum CodingKeys: String, CodingKey { case id, time, label }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        time = max(0, try c.decode(Double.self, forKey: .time))
        label = try c.decodeIfPresent(String.self, forKey: .label).flatMap { Self.isLegacyDefault($0) ? nil : $0 }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(time, forKey: .time)
        // Builds from before unlabelled moments require a label; they get the English default, which this build
        // reads back as no label.
        try c.encode(label ?? Self.legacyDefault, forKey: .label)
    }

    static let legacyDefault = "Marked moment"

    /// Earlier builds stored the English default label ("Marked moment", "Moment at 1:05") on every bookmark.
    static func isLegacyDefault(_ label: String) -> Bool {
        label == legacyDefault || label.wholeMatch(of: /Moment at (\d+:)?\d{1,2}:\d{2}/) != nil
    }
}
