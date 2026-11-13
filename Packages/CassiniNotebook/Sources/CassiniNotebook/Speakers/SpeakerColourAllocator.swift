import Foundation

/// Keeps authored slots, including foreign display hints at JSON's largest exact integer.
/// New slots normally follow the highest reservation. Once that domain is exhausted, allocation advances through
/// unused slots from zero without renumbering existing speakers. Identities compare by their exact UTF-8 bytes.
struct SpeakerColourAllocator {
    static let maximum = 9_007_199_254_740_991
    private(set) var byteAssignments: [Data: Int]
    private var occupied: Set<Int>
    private var vacantFallback: Bool
    private var next: Int

    /// Native draft IDs use this form. Foreign format IDs must keep their byte-keyed assignments instead.
    var assignments: [String: Int] {
        Dictionary(byteAssignments.compactMap { key, value in
            String(data: key, encoding: .utf8).map { ($0, value) }
        }, uniquingKeysWith: { first, _ in first })
    }

    init(_ assignments: [String: Int], reserving other: [String: Int] = [:]) {
        self.init(exactAssignments: Dictionary(uniqueKeysWithValues: assignments.map { (Data($0.key.utf8), $0.value) }),
                  reserving: Dictionary(uniqueKeysWithValues: other.map { (Data($0.key.utf8), $0.value) }))
    }

    init(exactAssignments assignments: [Data: Int], reserving other: [Data: Int] = [:]) {
        byteAssignments = assignments.merging(other) { assigned, _ in assigned }
        // An older reservation still occupies its slot even when that ID has a newer authored assignment.
        occupied = Set(assignments.values).union(other.values)
        let highest = max(assignments.values.max() ?? -1, other.values.max() ?? -1)
        vacantFallback = highest >= Self.maximum
        next = vacantFallback ? 0 : highest + 1
    }

    mutating func reserve(_ id: String) -> Int {
        let key = Data(id.utf8)
        if let existing = byteAssignments[key] { return existing }
        if vacantFallback {
            while next < Self.maximum && occupied.contains(next) { next += 1 }
            // Filling this entire domain cannot occur within a finite in-memory transcript.
            precondition(!occupied.contains(next), "Speaker colour slots exhausted")
        }
        let value = next
        byteAssignments[key] = value
        occupied.insert(value)
        if value == Self.maximum {
            vacantFallback = true
            next = 0
        } else {
            next = value + 1
        }
        return value
    }
}
