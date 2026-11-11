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

    @Test(arguments: ["2026-11-09T09:31:48+00:00", "2026-11-09T09:31:48z", "2026-11-09T09:31:48", "not a timestamp", ""])
    func unusableOptionalUtcDoesNotHideReadableWordsOrEraseLegacyDate(_ optional: String) throws {
        let bytes = try CassiniDocument.create(silence(), transcript: words, title: "English meeting", processing: JSONObject())
        var source = CassiniDocument.read(bytes)
        let legacy = "2026-11-08T08:15:00Z"
        var meeting = try #require(source.manifest?["meeting"]?.object)
        meeting["recordedAtUtc"] = .string(optional)
        source.manifest?["meeting"] = .object(meeting)
        source.comments = source.comments.filter { CassiniDocument.tagName($0) != "DATE" } + ["DATE=\(legacy)"]
        let output = try CassiniDocument.create(bytes, transcript: words, title: "English meeting", processing: JSONObject(), existing: source)
        let read = CassiniDocument.read(output)
        #expect(read.state == .ok)
        #expect(read.selected()?.transcript == words)
        #expect(read.manifest?["meeting"]?.object?["recordedAtUtc"] == .string(optional))
        #expect(comments(read) { $0 == "DATE" } == ["DATE=\(legacy)"])
    }

    @Test func nonStringOptionalUtcMetadataIsPreservedWithoutHidingTheTranscript() throws {
        let bytes = try CassiniDocument.create(silence(), transcript: words, title: "English meeting", processing: JSONObject())
        for optional in [JSON.int(7), .null, .array([])] {
            var source = CassiniDocument.read(bytes)
            var meeting = try #require(source.manifest?["meeting"]?.object)
            meeting["recordedAtUtc"] = optional
            source.manifest?["meeting"] = .object(meeting)
            let rewritten = try CassiniDocument.create(bytes, transcript: words, title: "English meeting", processing: JSONObject(), existing: source)
            let document = CassiniDocument.read(rewritten)
            #expect(document.state == .ok)
            #expect(document.selected()?.transcript == words)
            #expect(document.manifest?["meeting"]?.object?["recordedAtUtc"] == optional)
        }
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
        for legacyDate in ["2026-11-09T10:31:48+01:00", "2026-11-09t09:31:48Z",
                           "2026-11-09T09:31:48z", " 2026-11-09t09:31:48.250z ", created] {
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

    @Test(arguments: [false, true])
    func explicitStartFillsLegacyVerifiedDocumentsWithoutReplacingKnownUtc(_ alreadyKnown: Bool) throws {
        try withTemporaryDirectory { folder in
            let supplied = try #require(CassiniDocument.parseInstant(startText))
            let knownText = "2026-11-08T08:15:00.125Z"
            let known = try #require(CassiniDocument.parseInstant(knownText))
            let source = folder.appendingPathComponent("legacy.opus")
            try Data(try CassiniDocument.create(silence(), transcript: words, title: "English planning meeting",
                                               processing: JSONObject(), recordedAt: alreadyKnown ? known : nil)).write(to: source)
            let before = CassiniDocument.read(source)
            let after = try CassiniDocument.create(source, transcript: Transcript([Word("spk_1", 0, 20, "Welcome")]),
                title: "English planning meeting", processing: JSONObject(), existing: before, speakerLabels: [:],
                recordedAt: supplied, target: folder.appendingPathComponent("exported.opus"))
            let expected = alreadyKnown ? knownText : startText
            #expect(after.state == .ok)
            #expect(after.manifest?["meeting"]?.object?["recordedAtUtc"] == .string(expected))
            #expect(after.manifest?["meeting"]?.object?["id"] == before.manifest?["meeting"]?.object?["id"])
            #expect(after.manifest?["meeting"]?.object?["createdAtUtc"] == before.manifest?["meeting"]?.object?["createdAtUtc"])
            #expect(after.manifest?["integrity"] == before.manifest?["integrity"])
            #expect(Array(after.variants.dropLast().map(\.body)) == before.variants.map(\.body))
            #expect(comments(after) { $0 == "CASSINI_RECORDED_AT_UTC" } == ["CASSINI_RECORDED_AT_UTC=\(expected)"])
            #expect(comments(after) { $0 == "DATE" } == ["DATE=\(expected)"])
        }
    }

    @Test(arguments: [false, true])
    func explicitStartFillsCarriedDocumentsAndStaleLocalLabelsAreDropped(_ alreadyKnown: Bool) throws {
        let fixtures = CassiniDocumentCarryTests()
        let supplied = try #require(CassiniDocument.parseInstant(startText))
        let knownText = "2026-11-08T08:15:00.125Z"
        let known = try #require(CassiniDocument.parseInstant(knownText))
        var bytes = try fixtures.documentWithPrivateData()
        if alreadyKnown {
            bytes = try CassiniDocument.create(bytes, transcript: words, title: "English planning meeting",
                processing: JSONObject(), existing: CassiniDocument.read(bytes), recordedAt: known)
        }
        for carried in [try fixtures.unverifiedTwin(bytes), try fixtures.staleTwin(bytes)] {
            let before = CassiniDocument.read(carried)
            let after = CassiniDocument.read(try CassiniDocument.create(carried, transcript: words,
                title: "English planning meeting", processing: JSONObject(), carrying: before, recordedAt: supplied))
            let expected = alreadyKnown && before.state != .staleAudio ? knownText : startText
            #expect(after.state == .ok)
            #expect(after.manifest?["meeting"]?.object?["recordedAtUtc"] == .string(expected))
            #expect(after.manifest?["meeting"]?.object?["id"] == before.manifest?["meeting"]?.object?["id"])
            #expect(after.manifest?["x"]?.serialized() == before.manifest?["x"]?.serialized())
            #expect(after.manifest?["cassiniFutureField"]?.serialized() == before.manifest?["cassiniFutureField"]?.serialized())
            #expect(after.manifest?["meeting"]?.object?["futureMeetingField"]?.serialized() ==
                    before.manifest?["meeting"]?.object?["futureMeetingField"]?.serialized())
            #expect(comments(after) { $0 == "CASSINI_RECORDED_AT_UTC" } == ["CASSINI_RECORDED_AT_UTC=\(expected)"])
            #expect(comments(after) { $0 == "DATE" } == ["DATE=\(expected)"])
            if before.state == .staleAudio {
                #expect(after.manifest?["meeting"]?.object?["recordedAtLocal"] == nil)
                #expect(comments(after) { $0 == "CASSINI_RECORDED_AT_LOCAL" }.isEmpty)
            } else {
                #expect(after.manifest?["meeting"]?.object?["recordedAtLocal"] == .string("2026-10-30T09:15:00"))
                #expect(comments(after) { $0 == "CASSINI_RECORDED_AT_LOCAL" } == ["CASSINI_RECORDED_AT_LOCAL=2026-10-30T09:15:00"])
            }
        }
    }


    @Test(arguments: [false, true])
    func aLowLevelStaleResealDropsAllOldRecordingTimesUnlessTheCallerSuppliesOne(_ supplied: Bool) throws {
        try withTemporaryDirectory { folder in
            let fixtures = CassiniDocumentCarryTests()
            let seeded = try fixtures.documentWithPrivateData()
            let oldStart = try #require(CassiniDocument.parseInstant("2026-11-08T08:15:00.125Z"))
            let known = try CassiniDocument.create(seeded, transcript: words, title: "English meeting",
                processing: JSONObject(), existing: CassiniDocument.read(seeded), recordedAt: oldStart)
            let stale = try fixtures.staleTwin(known)
            let source = folder.appendingPathComponent("stale.opus")
            try Data(stale).write(to: source)
            let before = CassiniDocument.readChecked(source)
            #expect(before.state == .staleAudio)
            let suppliedStart = try #require(CassiniDocument.parseInstant(startText))
            let output = folder.appendingPathComponent("resealed.opus")
            let after = try CassiniDocument.create(source, transcript: words, title: "English replacement meeting",
                processing: JSONObject(), existing: nil, speakerLabels: [:], carrying: before,
                recordedAt: supplied ? suppliedStart : nil, target: output)
            #expect(after.state == .ok)
            #expect(after.manifest?["meeting"]?.object?["recordedAtLocal"] == nil)
            #expect(comments(after) { $0 == "CASSINI_RECORDED_AT_LOCAL" }.isEmpty)
            if supplied {
                #expect(after.manifest?["meeting"]?.object?["recordedAtUtc"] == .string(startText))
                #expect(comments(after) { $0 == "CASSINI_RECORDED_AT_UTC" } == ["CASSINI_RECORDED_AT_UTC=\(startText)"])
                #expect(comments(after) { $0 == "DATE" } == ["DATE=\(startText)"])
            } else {
                let created = try #require(after.manifest?["meeting"]?.object?["createdAtUtc"]?.string)
                #expect(after.manifest?["meeting"]?.object?["recordedAtUtc"] == nil)
                #expect(comments(after) { $0 == "CASSINI_RECORDED_AT_UTC" }.isEmpty)
                #expect(comments(after) { $0 == "DATE" } == ["DATE=\(created)"])
            }
            #expect(after.manifest?["meeting"]?.object?["id"] == before.manifest?["meeting"]?.object?["id"])
            #expect(after.manifest?["x"] == before.manifest?["x"])
            #expect(after.manifest?["meeting"]?.object?["futureMeetingField"] == before.manifest?["meeting"]?.object?["futureMeetingField"])
            #expect(try Data(contentsOf: source) == Data(stale))
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
