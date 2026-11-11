@testable import CassiniCore
import Foundation
import Testing

@Suite struct RecordingTimeTests {
    let words = Transcript([Word("spk_1", 0, 20, "Hello")])
    let startText = "2026-11-09T09:31:48.250Z"

    @Test func aKnownRecordingStartHasOneUtcMirrorAndOneDate() throws {
        let start = try #require(CassiniDocument.parseInstant(startText))
        let document = CassiniDocument.read(try CassiniDocument.create(
            silence(["date=1999-01-01", "DATE=2000-01-01", "X_CUSTOM=keep"]),
            transcript: words, title: "Meeting", processing: JSONObject(), recordedAt: start))
        #expect(document.state == .ok)
        #expect(document.manifest?["meeting"]?.object?["recordedAtUtc"] == .string(startText))
        #expect(document.manifest?["meeting"]?.object?["recordedAtLocal"] == nil)
        #expect(comments(document) { $0 == "CASSINI_RECORDED_AT_UTC" } == ["CASSINI_RECORDED_AT_UTC=\(startText)"])
        #expect(comments(document) { $0 == "DATE" } == ["DATE=\(startText)"])
        #expect(document.comments.contains("X_CUSTOM=keep"))
    }

    @Test func unknownStartWritesOnlyThePackStamp() throws {
        let document = CassiniDocument.read(try CassiniDocument.create(
            silence(["DATE=1999-01-01T00:00:00Z"]), transcript: words, title: "Meeting", processing: JSONObject()))
        let created = try #require(document.manifest?["meeting"]?.object?["createdAtUtc"]?.string)
        #expect(document.state == .ok)
        #expect(document.manifest?["meeting"]?.object?["recordedAtUtc"] == nil)
        #expect(comments(document) { $0 == "CASSINI_RECORDED_AT_UTC" }.isEmpty)
        #expect(comments(document) { $0 == "DATE" } == ["DATE=\(created)"])
    }

    @Test(arguments: ["2026-11-09T09:31:48+00:00", "2026-11-09T09:31:48", "not a timestamp", ""])
    func recordedAtUtcMustBeAnInstantEndingInZ(_ invalid: String) throws {
        let document = CassiniDocument.read(try CassiniDocument.create(silence(), transcript: words,
                                                                      title: "Meeting", processing: JSONObject()))
        var manifest = try #require(document.manifest)
        var meeting = try manifest.object("meeting")
        meeting["recordedAtUtc"] = .string(invalid)
        manifest["meeting"] = .object(meeting)
        #expect(throws: CassiniError.self) { try CassiniDocument.validateManifest(manifest) }
    }

    @Test func rewriteKeepsTheStartAndReplacesStaleMirrors() throws {
        try withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("source.opus")
            let start = try #require(CassiniDocument.parseInstant(startText))
            try Data(try CassiniDocument.create(silence(), transcript: words, title: "Meeting", processing: JSONObject(),
                                               recordedAt: start)).write(to: source)
            var existing = CassiniDocument.read(source)
            existing.comments += ["cassini_recorded_at_utc=1999-01-01T00:00:00Z", "date=1999-01-01T00:00:00Z"]
            let after = try CassiniDocument.retitle(source, existing: existing, title: "Renamed",
                                                    target: dir.appendingPathComponent("retitled.opus"))
            #expect(after.manifest?["meeting"]?.object?["recordedAtUtc"] == .string(startText))
            #expect(comments(after) { $0 == "DATE" } == ["DATE=\(startText)"])
            #expect(comments(after) { $0 == "CASSINI_RECORDED_AT_UTC" } == ["CASSINI_RECORDED_AT_UTC=\(startText)"])
            #expect(after.variants.map(\.body) == existing.variants.map(\.body))
            #expect(after.manifest?["integrity"] == existing.manifest?["integrity"])
        }
    }

    @Test func aResealPreservesGenuineLegacyDateButNeverPromotesTheOldPackStamp() throws {
        let initial = CassiniDocument.read(try CassiniDocument.create(silence(), transcript: words,
                                                                     title: "Meeting", processing: JSONObject()))
        let created = try #require(initial.manifest?["meeting"]?.object?["createdAtUtc"]?.string)
        for legacyDate in ["2026-11-09T10:31:48+01:00", created] {
            var source = initial
            source.comments = source.comments.filter { CassiniDocument.tagName($0) != "DATE" } + ["DATE=\(legacyDate)"]
            let after = CassiniDocument.read(try CassiniDocument.create(silence(source.comments), transcript: words,
                                                                         title: "Resealed", processing: JSONObject(), carrying: source))
            let packed = try #require(after.manifest?["meeting"]?.object?["createdAtUtc"]?.string)
            #expect(after.state == .ok)
            #expect(after.manifest?["meeting"]?.object?["recordedAtUtc"] == nil)
            #expect(comments(after) { $0 == "DATE" } == ["DATE=\(legacyDate == created ? packed : legacyDate)"])
        }
    }
}

@Suite(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)))
struct RecordingTimeConformanceTests {
    @Test(arguments: ["027-recorded-at-utc", "028-date-is-created-at", "029-date-with-offset"])
    func pinnedRecordingTimeVectorsArePresentAndReadable(_ name: String) throws {
        #expect(ConformanceVector.all.contains { $0.id == name })
        let document = CassiniDocument.read(try Conformance.vector(name))
        #expect(document.state == .ok)
        #expect(document.warnings.isEmpty)
        #expect(document.selected()?.transcript?.words.count == 3)
    }
}
