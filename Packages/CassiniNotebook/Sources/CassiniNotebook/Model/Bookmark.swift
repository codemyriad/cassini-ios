import Foundation

public struct Bookmark: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var time: Double
    public var label: String
    public init(id: UUID = UUID(), time: Double, label: String = "Marked moment") {
        self.id = id; self.time = max(0, time); self.label = label
    }
}
