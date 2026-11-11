#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import CassiniCore
@testable import CassiniNotebook

/// D95's oracle is cassini-format 32f37a6's independent standard-library reader, not a second Swift implementation.
@Suite(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)))
struct RecordedMeetingReaderParityTests {
    private static let tool = Conformance.directory.appendingPathComponent("../../tools/cassini-read-pure.py").standardized
    private static let toolSHA256 = "5c18ee20ae60a449202d992d9a75287db56860c07d77509358e19ad2a77765d6"

    @Test(arguments: ["027-recorded-at-utc", "028-date-is-created-at", "029-date-with-offset"])
    func publishedVectorsMatchReferenceWhen(_ name: String) throws {
        let source = name.hasPrefix("027") ? "recordedAtUtc" : name.hasPrefix("028") ? "recordedAtLocal" : "DATE"
        try assertParity(Conformance.vector(name), expectedSource: source)
        try assertExportParity(Conformance.vector(name), expectedSource: source)
    }

    @Test func generatedRFC3339FormsAndPriorityMatchReferenceWhen() throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let dates = [
            "2026-11-09t09:31:48Z",
            "2026-11-09T09:31:48z",
            "2026-11-09 10:31:48+01:00",
            "2026-11-09t10:31:48.123456789+01:00",
            " 2026-11-09t09:31:48.250z "
        ]
        for (index, date) in dates.enumerated() {
            let file = folder.appendingPathComponent("English-date-\(index).opus")
            try Data(document(date: date)).write(to: file)
            try assertParity(file, expectedSource: "DATE")
            try assertExportParity(file, expectedSource: "DATE")
        }
        let cases: [(String, String?, String?, String?, String?)] = [
            ("utc-priority", "2026-11-09T23:59:59+09:00", "2026-11-09T09:31:48.250Z", "2026-11-09T01:00:00", "recordedAtUtc"),
            ("equal-seal-falls-back-local", "2026-11-09t10:40:48.000000+01:00", nil, "2026-11-09T01:00:00", "recordedAtLocal"),
            ("offsetless-date-falls-back-local", "2026-11-09T09:31:48", nil, "2026-11-09T01:00:00", "recordedAtLocal"),
            ("non-z-utc-falls-back-date", "2026-11-09t09:31:48z", "2026-11-09T01:00:00+00:00", nil, "DATE"),
            ("lower-z-utc-falls-back-local", nil, "2026-11-09T01:00:00z", "2026-11-09T01:00:00", "recordedAtLocal"),
            ("invalid-utc-falls-back-local", nil, "not a timestamp", "2026-11-09T01:00:00", "recordedAtLocal"),
            ("invalid-utc-with-no-start-is-unknown", nil, "not a timestamp", nil, nil),
            ("only-seal-is-unknown", nil, nil, nil, nil)
        ]
        for (name, date, utc, local, source) in cases {
            let file = folder.appendingPathComponent("English-\(name).opus")
            try Data(document(date: date, recordedAtUTC: utc, recordedAtLocal: local)).write(to: file)
            try assertParity(file, expectedSource: source)
            try assertExportParity(file, expectedSource: source)
        }
    }

    @Test(arguments: ["2026-02-30T09:31:48Z", "2026-11-09T24:00:00Z", "1900-02-29T09:31:48Z",
                      "2026-11-09T09:60:00Z", "2026-11-09T09:31:60Z"])
    func impossibleUTCNeverOverridesValidDATEThroughExportAndReimport(_ timestamp: String) throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("English impossible UTC.opus")
        let date = "2026-11-08T08:15:00.123456Z"
        try Data(document(date: date, recordedAtUTC: timestamp)).write(to: file)
        #expect(CassiniDocument.readChecked(file).manifest?["meeting"]?.object?["recordedAtUtc"] == .string(timestamp))
        try assertParity(file, expectedSource: "DATE")
        try assertExportParity(file, expectedSource: "DATE")
    }

    @Test func acceptedLegacyUTCCanonicalizesWithoutRoundingFractionsOrChangingPackStampEquality() throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let cases: [(String, String?, String, String?)] = [
            ("lower-t-utc", " 2026-11-09t09:31:48.123456789Z ", "2026-11-09T09:40:48Z", "recordedAtUtc"),
            ("space-utc", "2026-11-09 09:31:48.000001Z", "2026-11-09T09:40:48Z", "recordedAtUtc"),
            ("micro-pack-stamp", nil, "2026-11-09t09:40:48.123456789Z", "recordedAtLocal")
        ]
        for (name, utc, created, expected) in cases {
            let file = folder.appendingPathComponent("English \(name).opus")
            let date = utc == nil ? " 2026-11-09 10:40:48.123456999+01:00 " : "2026-11-08T08:15:00Z"
            try Data(document(date: date, recordedAtUTC: utc, recordedAtLocal: "2026-11-07T12:15:00",
                              createdAtUTC: created, processedAtUTC: "2026-11-10t09:31:48.999999999z")).write(to: file)
            try assertParity(file, expectedSource: expected)
            try assertExportParity(file, expectedSource: expected)
        }
    }

    @Test(arguments: ["reseal", "retitle", "relabel"])
    func everyWriterCanonicalizesUsableFieldsWithoutLosingFractionalDigits(_ operation: String) throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("English legacy field casing.opus")
        let bytes = try document(date: "2026-11-08T08:15:00Z", recordedAtUTC: " 2026-11-09t09:31:48.123456789Z ",
            recordedAtLocal: "2026-11-09T09:31:48", createdAtUTC: "2026-11-09t09:40:48.000001999Z",
            processedAtUTC: "2026-11-10 09:31:48.999999999z")
        try Data(bytes).write(to: input)
        let source = CassiniDocument.readChecked(input)
        #expect(source.state == .ok)
        #expect(throws: (any Error).self) { try ManifestSchema.check(source) }
        let output = folder.appendingPathComponent("English canonical fields.opus")
        let rewritten: CassiniDocument
        switch operation {
        case "retitle": rewritten = try CassiniDocument.retitle(input, existing: source, title: "English renamed meeting", target: output)
        case "relabel": rewritten = try CassiniDocument.relabel(input, existing: source, labels: ["a": "Jordan"], target: output)
        default: rewritten = try CassiniDocument.create(input, transcript: try #require(source.selected()?.transcript),
            title: "English rewritten meeting", processing: JSONObject(), existing: source, speakerLabels: [:], target: output)
        }
        try ManifestSchema.check(rewritten)
        #expect(rewritten.manifest?["meeting"]?.object?["createdAtUtc"] == .string("2026-11-09T09:40:48.000001999Z"))
        #expect(rewritten.manifest?["meeting"]?.object?["recordedAtUtc"] == .string("2026-11-09T09:31:48.123456789Z"))
        #expect(rewritten.manifest?["meeting"]?.object?["processedAtUtc"] == .string("2026-11-10T09:31:48.999999999Z"))
        #expect(rewritten.comments.contains("CASSINI_RECORDED_AT_UTC=2026-11-09T09:31:48.123456789Z"))
        #expect(rewritten.comments.contains("DATE=2026-11-09T09:31:48.123456789Z"))
        #expect(MeetingTime.read(rewritten) == MeetingTime.read(source))
        try assertParity(output, expectedSource: "recordedAtUtc")
        #expect(Array(rewritten.variants.prefix(source.variants.count)).map(\.body) == source.variants.map(\.body))
        #expect(try OggOpus.scan(output).digest() == OggOpus.scan(input).digest())
        #expect(try Data(contentsOf: input) == Data(bytes))
    }

    @Test(arguments: ["2026-11-09t09:31:48", "2026-02-30T09:31:48", "2026-11-09T24:00:00",
                      " 2026-11-09T09:31:48 ", "2026-11-09T09:31:48.125", "2026-11-09T09:31:48+01:00"])
    func unusableOptionalLocalLabelIsOmittedRatherThanAssignedAnInstant(_ local: String) throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let input = folder.appendingPathComponent("English unusable local label.opus")
        try Data(document(recordedAtLocal: local)).write(to: input)
        let source = CassiniDocument.readChecked(input)
        // The tolerant reference reader exposes any nonempty local string as stored. A producer must
        // discard an unusable label to meet the schema; it never converts that label into an instant.
        try assertParity(input, expectedSource: "recordedAtLocal")
        let output = folder.appendingPathComponent("English cleaned local label.opus")
        _ = try CassiniDocument.create(input, transcript: try #require(source.selected()?.transcript),
            title: "English cleaned meeting", processing: JSONObject(), existing: source, speakerLabels: [:], target: output)
        let written = CassiniDocument.readChecked(output)
        #expect(written.manifest?["meeting"]?.object?["recordedAtLocal"] == nil)
        #expect(written.manifest?["meeting"]?.object?["recordedAtUtc"] == nil)
        try ManifestSchema.check(written)
        try assertParity(output, expectedSource: nil)
    }

    @Test func damagedAndUnknownFormatsCannotRecoverAWhenFromDATEOrAnInjectedManifest() throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let valid = try document(date: "2026-11-09T23:59:59+09:00", recordedAtUTC: "2026-11-09T09:31:48Z")
        let manifest = try #require(CassiniDocument.read(valid).manifest)
        let cases: [(String, DocumentState, [UInt8])] = [
            ("damaged", .invalidMetadata, try PortableFixtures.rewritingComments(valid) {
                $0.hasPrefix("CASSINI_PAYLOAD_SHA256=") ? "CASSINI_PAYLOAD_SHA256=" + String(repeating: "0", count: 64) : $0
            }),
            ("unknown", .unknownFormat, try PortableFixtures.rewritingComments(valid) {
                $0.hasPrefix("CASSINI_FORMAT=") ? "CASSINI_FORMAT=org.cassini.portable-meeting/99" : $0
            })
        ]
        for (name, state, bytes) in cases {
            let file = folder.appendingPathComponent("English-\(name)-DATE-bait.opus")
            try Data(bytes).write(to: file)
            let parsed = CassiniDocument.read(bytes)
            #expect(parsed.state == state)
            try assertParity(file, expectedSource: nil)
            // Even an adapter accidentally retaining a readable manifest must honor the document's failed state.
            var injected = parsed
            injected.manifest = manifest
            try assertParity(file, expectedSource: nil, document: injected)
        }
    }

    /// Build the input envelope directly: invoking the producer here would sanitize the malformed legacy
    /// timestamp before the reader/export regression sees it. Preserve valid payload hashes and real audio.
    private func document(date: String? = nil, recordedAtUTC: String? = nil,
                          recordedAtLocal: String? = nil, createdAtUTC: String = "2026-11-09T09:40:48Z",
                          processedAtUTC: String? = nil) throws -> [UInt8] {
        let transcript = Transcript([Word("a", 0, 300, "Hello"), Word("a", 400, 700, "everyone")], language: "en")
        let original = try CassiniDocument.create(PortableFixtures.silence(), transcript: transcript,
            title: "English reader parity", processing: JSONObject(), speakerLabels: ["a": "Alex"])
        let parsed = CassiniDocument.read(original)
        var manifest = try #require(parsed.manifest)
        var meeting = try manifest.object("meeting")
        meeting["createdAtUtc"] = .string(createdAtUTC)
        if let recordedAtUTC { meeting["recordedAtUtc"] = .string(recordedAtUTC) }
        if let recordedAtLocal { meeting["recordedAtLocal"] = .string(recordedAtLocal) }
        if let processedAtUTC { meeting["processedAtUtc"] = .string(processedAtUTC) }
        manifest["meeting"] = .object(meeting)
        let kept = parsed.comments.filter {
            let name = CassiniDocument.tagName($0)
            return !CassiniDocument.isDerived(name) && name != "DATE"
        }
        let comments = kept + (try CassiniDocument.copies(of: manifest))
            + (try CassiniDocument.manifestTags(manifest)) + ["DATE=\(date ?? createdAtUTC)"]
        return try OggOpus.mux(OggOpus.read(original), tags: CassiniDocument.tagsPacket(comments))
    }

    /// Invoke the real writer, not PortableExportService's unchanged-import byte-copy fast path.
    private func assertExportParity(_ original: URL, expectedSource: String?) throws {
        let folder = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = CassiniDocument.readChecked(original)
        #expect(source.state == .ok)
        let portable = try #require(PortableTranscript(source))
        let note = ImportedNote.make(id: UUID(), displayName: nil, fallbackTitle: "English export parity",
            sha256: "synthetic", importedAt: Date(timeIntervalSince1970: 1_794_212_100),
            audio: ImportedAudio(filename: original.lastPathComponent, duration: 1), document: portable)
        let output = folder.appendingPathComponent("rewritten.opus")
        try PortableTranscript.export(note: note, opus: original, destination: output,
                                      unassignedLabel: "Unknown speaker", source: source)
        let rewritten = CassiniDocument.readChecked(output)
        #expect(rewritten.state == .ok)
        try ManifestSchema.check(rewritten)
        #expect(MeetingTime.read(rewritten) == portable.meetingTime)
        #expect(rewritten.variants.count > source.variants.count, "Exercise resealing rather than byte copying")
        try assertParity(output, expectedSource: expectedSource)
        if expectedSource == "DATE" {
            func dateTag(_ document: CassiniDocument) -> String? {
                document.comments.first { $0.split(separator: "=", maxSplits: 1).first?.uppercased() == "DATE" }
            }
            #expect(dateTag(rewritten) == dateTag(source), "Keep valid legacy DATE bytes, including lowercase t/z")
        }
    }

    private func assertParity(_ file: URL, expectedSource: String?, document: CassiniDocument? = nil) throws {
        let reference = try referenceWhen(file)
        #expect(reference.source == expectedSource)
        let actual = MeetingTime.read(try document ?? CassiniDocument.read([UInt8](Data(contentsOf: file))))
        switch actual {
        case .instant(let date):
            #expect(reference.kind == "instant")
            // Python truncates to six fractional digits. Compare integer microseconds, avoiding epoch-float ULP noise.
            #expect(reference.epochMicros == Int64((date.timeIntervalSince1970 * 1_000_000).rounded()))
        case .local(let text):
            #expect(reference.kind == "local")
            #expect(reference.localText == text)
        case .unknown: #expect(reference.kind == "unknown")
        }
    }

    private struct ReferenceWhen: Decodable {
        let kind: String
        let source: String?
        let epochMicros: Int64?
        let localText: String?
    }

    private func referenceWhen(_ file: URL) throws -> ReferenceWhen {
        let hash = SHA256.hash(data: try Data(contentsOf: Self.tool)).map { String(format: "%02x", $0) }.joined()
        #expect(hash == Self.toolSHA256, "Reference reader must match the pinned cassini-format 32f37a6")
        let python = #"""
        import datetime, json, runpy, sys
        reader = runpy.run_path(sys.argv[1])
        result, _ = reader['read_file'](sys.argv[2])
        source, value = result.get('when', (None, None))
        out = {'source': source, 'kind': 'unknown'}
        if source in ('recordedAtUtc', 'DATE'):
            delta = reader['_instant'](value) - datetime.datetime(1970, 1, 1, tzinfo=datetime.timezone.utc)
            out.update(kind='instant', epochMicros=(delta.days * 86400 + delta.seconds) * 1000000 + delta.microseconds)
        elif source == 'recordedAtLocal':
            out.update(kind='local', localText=value)
        print(json.dumps(out))
        """#
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-B", "-X", "utf8", "-c", python, Self.tool.path, file.path]
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit() // Process completion is the event; the suite runner supplies the outer hang guard.
        #expect(process.terminationStatus == 0, "\(String(decoding: data, as: UTF8.self))")
        return try JSONDecoder().decode(ReferenceWhen.self, from: data)
    }
}
#endif
