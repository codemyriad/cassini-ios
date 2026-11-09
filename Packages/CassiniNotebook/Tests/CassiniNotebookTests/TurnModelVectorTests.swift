import Foundation
import Testing
@testable import CassiniNotebook

/// Shared gocassini viewer goldens, generated at the pinned commit in the fixture README.
/// Keep the expected files unchanged: changing the viewer requires regenerating the shared vectors.
@Suite struct TurnModelVectorTests {
    private static let fixtures = [
        "acknowledgment", "competing", "monologue", "overlapping-turns", "brief-reply", "seam-gap"
    ]
    private static let viewerCommit = "1111155cb0017b47c072a8662c54f28ad7c44223"

    @Test(arguments: fixtures)
    func matchesViewerVector(_ fixture: String) throws {
        let input: Input = try load("\(fixture).words.json")
        let expected: Expected = try load("\(fixture).expected.json")
        #expect(input.format == "cassini.words.v1")
        #expect(expected.format == "cassini.render-vector.v1")
        #expect(expected.source.repo == "codemyriad/gocassini")
        #expect(expected.source.commit == Self.viewerCommit)
        #expect(expected.fixture == "\(fixture).words.json")
        #expect(input.items.allSatisfy { !$0.text.isEmpty && $0.text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil })

        let words = input.items.map {
            TurnModel.Word(speaker: $0.speaker, startMs: $0.startMs, endMs: $0.endMs,
                           text: $0.text, lowConfidenceSpeaker: $0.lowConfidenceSpeaker ?? false)
        }
        let rows = TurnModel.rows(of: words)
        let actual = rows.map { row in
            ComparedRow(speaker: row.speaker, continuation: row.continuation,
                        startMs: row.startMs, endMs: row.endMs, over: row.over, crosstalk: row.crosstalk,
                        members: row.members.map { member in
                            switch member.kind {
                            case .words:
                                // The vector schema gives speaker/crosstalk only to interjection members.
                                ComparedMember(kind: "words", speaker: nil, crosstalk: nil,
                                               wordIndices: member.wordIndices, text: member.text)
                            case .interjection:
                                ComparedMember(kind: "interjection", speaker: member.speaker,
                                               crosstalk: member.crosstalk,
                                               wordIndices: member.wordIndices, text: member.text)
                            }
                        })
        }

        // Check uncoalesced output too: no duplicated/lost atoms, punctuation changes or word splitting.
        let renderedIndices = actual.flatMap(\.members).flatMap(\.wordIndices)
        #expect(renderedIndices.sorted() == Array(input.items.indices))
        for row in actual {
            for member in row.members {
                #expect(!member.wordIndices.isEmpty)
                let valid = member.wordIndices.allSatisfy { input.items.indices.contains($0) }
                #expect(valid)
                if valid {
                    #expect(member.text == member.wordIndices.map { input.items[$0].text }.joined(separator: " "))
                }
            }
        }
        // Adjacent own-speech block seams are explicitly informative in the shared README. Only
        // those seams may disappear; chips, ordering and every row field still compare exactly.
        #expect(actual.map(coalescingWords) == expected.rows.map(coalescingWords))
    }

    private func coalescingWords(_ row: ComparedRow) -> ComparedRow {
        var result = row
        result.members = []
        for member in row.members {
            if member.kind == "words", result.members.last?.kind == "words" {
                let index = result.members.count - 1
                result.members[index].wordIndices += member.wordIndices
                result.members[index].text += " " + member.text
            } else {
                result.members.append(member)
            }
        }
        return result
    }

    private func load<T: Decodable>(_ filename: String) throws -> T {
        let resource = try #require(Bundle.module.url(forResource: filename, withExtension: nil,
                                                     subdirectory: "interjections"))
        return try JSONDecoder().decode(T.self, from: Data(contentsOf: resource))
    }

    private struct Input: Decodable {
        var format: String
        var items: [Item]
        struct Item: Decodable {
            var speaker: String?
            var startMs: Double
            var endMs: Double
            var text: String
            var lowConfidenceSpeaker: Bool?
        }
    }
    private struct Expected: Decodable {
        var format: String
        var source: Source
        var fixture: String
        var rows: [ComparedRow]
        struct Source: Decodable { var repo: String; var commit: String }
    }
    private struct ComparedRow: Decodable, Equatable {
        var speaker: String?
        var continuation: Bool
        var startMs: Double
        var endMs: Double
        var over: [String]
        var crosstalk: Bool
        var members: [ComparedMember]
    }
    private struct ComparedMember: Decodable, Equatable {
        var kind: String
        var speaker: String?
        var crosstalk: Bool?
        var wordIndices: [Int]
        var text: String
    }
}
