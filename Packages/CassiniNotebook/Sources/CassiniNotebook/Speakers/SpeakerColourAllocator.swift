import Foundation

/// Preserves authored slots, including foreign display hints at JSON's largest exact integer.
/// Normal allocation is max + 1. Only when that domain is exhausted, new identities use their reservation ordinal;
/// equal slots are valid display hints, and no existing speaker is renumbered. No extra persisted cursor is needed.
struct SpeakerColourAllocator {
    static let maximum = 9_007_199_254_740_991
    private(set) var assignments: [String: Int]
    private var reserved: Set<String>
    private var ordinalFallback: Bool
    private var next: Int

    init(_ assignments: [String: Int], reserving other: [String: Int] = [:]) {
        self.assignments = assignments.merging(other) { assigned, _ in assigned }
        reserved = Set(assignments.keys).union(other.keys)
        let maximum = max(assignments.values.max() ?? -1, other.values.max() ?? -1)
        ordinalFallback = maximum >= Self.maximum
        next = ordinalFallback ? reserved.count : maximum + 1
    }

    mutating func reserve(_ id: String) -> Int {
        if let existing = assignments[id] { return existing }
        let value = next
        assignments[id] = value
        reserved.insert(id)
        if ordinalFallback || value == Self.maximum {
            ordinalFallback = true
            next = reserved.count
        } else {
            next = value + 1
        }
        return value
    }
}
