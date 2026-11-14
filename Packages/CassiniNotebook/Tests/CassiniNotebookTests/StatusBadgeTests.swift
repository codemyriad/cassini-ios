import Foundation
import Testing
@testable import CassiniNotebook

struct StatusBadgeTests {
    private struct Cases: Decodable {
        var version: Int
        var vectors: [Meeting]
        var entryVectors: [Entry]
        struct Meeting: Decodable {
            var id: String
            var fields: BadgeFields
            var badge: BadgePresentation?
            var canWriteDown: Bool?
        }
        struct Entry: Decodable {
            var id: String
            var scope: String
            var fields: Fields
            var badge: BadgePresentation
            struct Fields: Decodable { var importing: Bool }
        }
    }
    private struct Catalog: Decodable {
        var entries: [Item]
        struct Item: Decodable {
            var id: String
            var en: String
            var plural: [String: String]?
            var l10n: [String: Translation]?
            struct Translation: Decodable { var text: String; var plural: [String: String]? }
            func template(_ language: String) -> String { language == "en" ? en : l10n![language]!.text }
        }
        func provider(_ language: String) -> StatusBadges.Text {
            let selected = entries.filter { $0.id.hasPrefix("states.badge.") || $0.id == "meeting.interruptedAt" }
            let items = Dictionary(uniqueKeysWithValues: selected.map { ($0.id, $0.template(language)) })
            return { items[$0]! }
        }
    }
    private struct Format: Decodable {
        var version: Int
        var liveBadge: [Live]
        var eta: [ETA]
        struct Live: Decodable { var ms: Int64; var out: String }
        struct ETA: Decodable { var minutes: Int; var out: String }
    }
    private let languages = ["en", "it", "fr", "es", "pt-BR", "pt-PT"]

    private func data(_ path: String) throws -> Data {
        let folder = try #require(Bundle.module.url(forResource: "status-badges", withExtension: nil))
        return try Data(contentsOf: folder.appendingPathComponent(path))
    }
    private func load<T: Decodable>(_ path: String, as: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(T.self, from: data(path))
    }

    @Test func everySharedMeetingAndImportEntryMatchesItsWholeExpectedPresentation() throws {
        let cases: Cases = try load("vectors/states/states-vectors.json")
        let catalog: Catalog = try load("strings/strings.json")
        #expect(cases.version == 3 && cases.vectors.count == 18 && cases.entryVectors.count == 1)
        let raw = try #require(JSONSerialization.jsonObject(with: data("vectors/states/states-vectors.json")) as? [String: Any])
        let meetings = try #require(raw["vectors"] as? [[String: Any]])
        let entries = try #require(raw["entryVectors"] as? [[String: Any]])
        for (index, vector) in cases.vectors.enumerated() {
            let actual = StatusBadges.meeting(vector.fields, text: catalog.provider("en"))
            #expect(actual == vector.badge, "\(vector.id)")
            if let expected = vector.canWriteDown { #expect(StatusBadges.canWriteDown(vector.fields) == expected, "\(vector.id)") }
            if let actual {
                let bytes = try JSONEncoder().encode(actual)
                let object = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
                #expect(Set(object.keys) == Set(["kind", "text", "tint", "glyph"]))
                let expected = try #require(meetings[index]["badge"] as? NSDictionary)
                #expect(NSDictionary(dictionary: object).isEqual(expected), "Full raw expected badge: \(vector.id)")
                #expect(try JSONDecoder().decode(BadgePresentation.self, from: bytes) == actual)
            } else {
                #expect(meetings[index]["badge"] is NSNull)
            }
        }
        for (index, vector) in cases.entryVectors.enumerated() {
            #expect(vector.scope == "import-entry")
            let actual = try #require(StatusBadges.entry(importing: vector.fields.importing, text: catalog.provider("en")))
            #expect(actual == vector.badge)
            let encoded = try JSONEncoder().encode(actual)
            let object = try #require(JSONSerialization.jsonObject(with: encoded) as? NSDictionary)
            let expected = try #require(entries[index]["badge"] as? NSDictionary)
            #expect(object.isEqual(expected))
        }
        #expect(StatusBadges.entry(importing: false, text: catalog.provider("en")) == nil)
    }

    @Test func liveClockAndCompactETAUseFormatV5ThroughTheProductionFormatter() throws {
        let format: Format = try load("vectors/format/format-vectors.json")
        let catalog: Catalog = try load("strings/strings.json")
        #expect(format.version == 5)
        for vector in format.liveBadge {
            #expect(StatusBadges.liveClock(milliseconds: vector.ms) == vector.out)
            let badge = StatusBadges.meeting(.init(lifecycle: .recording, liveMs: vector.ms), text: catalog.provider("en"))
            #expect(badge?.text == catalog.provider("en")("states.badge.recording").replacingOccurrences(of: "{liveBadge}", with: vector.out))
        }
        for vector in format.eta {
            #expect(StatusBadges.transcribing(etaMinutes: vector.minutes, text: catalog.provider("en")).text == vector.out)
        }
        #expect(StatusBadges.liveClock(milliseconds: -1) == "0:00")
        let fallback = StatusBadges.meeting(.init(lifecycle: .recording, durationMs: 303_000), text: catalog.provider("en"))
        #expect(fallback?.text == catalog.provider("en")("states.badge.recording").replacingOccurrences(of: "{liveBadge}", with: "5:03"))
    }

    @Test func everyCatalogLocaleFlowsThroughTheSameProductionSelectorAndNamedInterpolation() throws {
        let cases: Cases = try load("vectors/states/states-vectors.json")
        let catalog: Catalog = try load("strings/strings.json")
        for language in languages {
            let text = catalog.provider(language)
            for vector in cases.vectors {
                let localized = StatusBadges.meeting(vector.fields, text: text)
                #expect(localized?.kind == vector.badge?.kind && localized?.tint == vector.badge?.tint && localized?.glyph == vector.badge?.glyph)
                guard let expected = vector.badge, let localized else { continue }
                let key: String
                switch expected.kind {
                case .transcribing:
                    key = vector.fields.etaMinutes.map { $0 < 0 ? "states.badge.transcribing.noEta" : $0 == 0 ? "states.badge.transcribing.underMinute" : "states.badge.transcribing" }
                        ?? "states.badge.transcribing.noEta"
                default: key = "states.badge." + expected.kind.rawValue
                }
                let template = text(key)
                switch expected.kind {
                case .recording:
                    let timer = StatusBadges.liveClock(milliseconds: vector.fields.liveMs ?? vector.fields.durationMs ?? 0)
                    #expect(localized.text == template.replacingOccurrences(of: "{liveBadge}", with: timer))
                case .transcribing:
                    #expect(localized.text == template.replacingOccurrences(of: "{n}", with: String(vector.fields.etaMinutes ?? 0)))
                default: #expect(localized.text == template)
                }
            }
            #expect(StatusBadges.entry(importing: true, text: text)?.text == text("states.badge.importing"))
            #expect(StatusBadges.interruptedAt(position: "12:48", text: text)
                == text("meeting.interruptedAt").replacingOccurrences(of: "{position}", with: "12:48"))
            let interrupted = StatusBadges.meeting(.init(interruptedAtMs: 768_000), text: text)
            #expect(interrupted?.text == text("states.badge.interrupted"), "The badge never gains the detail position")
            let eta = try #require(catalog.entries.first { $0.id == "states.badge.transcribing" })
            let plurals = language == "en" ? eta.plural! : eta.l10n![language]!.plural!
            for (category, template) in plurals {
                let n = category == "one" ? 1 : 2
                #expect(StatusBadges.transcribing(etaMinutes: n, text: text).text == template.replacingOccurrences(of: "{n}", with: String(n)))
            }
        }
    }

    @Test func fallbackDisplayDoesNotChangeReadPolicyAndImportNeverEntersMeetingPrecedence() throws {
        let catalog: Catalog = try load("strings/strings.json")
        let text = catalog.provider("en")
        for eta in [nil, -1, Int.min] as [Int?] {
            let badge = StatusBadges.transcribing(etaMinutes: eta, text: text)
            #expect(badge.text == text("states.badge.transcribing.noEta"))
            #expect(badge.kind == .transcribing && badge.tint == .neutral && badge.glyph == .spinner)
        }
        #expect(StatusBadges.meeting(.init(error: .init(action: "")), text: text)?.kind == .needsAttention,
                "Non-null action, including empty, preserves shared precedence")
        #expect(StatusBadges.meeting(.init(interruptedAtMs: 0, error: .init(action: nil)), text: text)?.kind == .interrupted)
        #expect(StatusBadges.canWriteDown(.init(origin: .received, transcript: .failed)))
        #expect(!StatusBadges.canWriteDown(.init(lifecycle: .saving)))
        let importingLifecycle = Data(#"{"lifecycle":"importing","origin":"own","transcript":"none"}"#.utf8)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(BadgeFields.self, from: importingLifecycle) }
        for invalid in ["true", "1.5", #""4""#] {
            let bytes = Data("{\"lifecycle\":\"saved\",\"origin\":\"own\",\"transcript\":\"running\",\"etaMinutes\":\(invalid)}".utf8)
            #expect(throws: DecodingError.self) { try JSONDecoder().decode(BadgeFields.self, from: bytes) }
        }
    }
}
