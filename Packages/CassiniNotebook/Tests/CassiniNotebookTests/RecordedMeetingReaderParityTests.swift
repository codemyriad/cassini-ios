#if os(macOS)
import CryptoKit
import Foundation
import Testing
import CassiniCore
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

    private func document(date: String? = nil, recordedAtUTC: String? = nil,
                          recordedAtLocal: String? = nil) throws -> [UInt8] {
        let transcript = Transcript([Word("a", 0, 300, "Hello"), Word("a", 400, 700, "everyone")], language: "en")
        let audio = try PortableFixtures.silence()
        let original = try CassiniDocument.create(audio, transcript: transcript, title: "English reader parity",
                                                  processing: JSONObject(), speakerLabels: ["a": "Alex"])
        var base = CassiniDocument.read(original)
        var manifest = try #require(base.manifest)
        var meeting = try manifest.object("meeting")
        meeting["createdAtUtc"] = .string("2026-11-09T09:40:48Z")
        if let recordedAtUTC { meeting["recordedAtUtc"] = .string(recordedAtUTC) }
        if let recordedAtLocal { meeting["recordedAtLocal"] = .string(recordedAtLocal) }
        manifest["meeting"] = .object(meeting)
        base.manifest = manifest
        // Keep the fixture's DATE equal to its deterministic pack stamp before a deliberate legacy override.
        // Otherwise the original creation clock would masquerade as a genuine historical DATE on reseal.
        base.comments = base.comments.map {
            $0.split(separator: "=", maxSplits: 1).first?.uppercased() == "DATE" ? "DATE=2026-11-09T09:40:48Z" : $0
        }
        let sealed = try CassiniDocument.create(audio, transcript: transcript, title: "English reader parity",
                                                processing: JSONObject(), existing: base)
        guard let date else { return sealed }
        let parsed = CassiniDocument.read(sealed)
        let comments = parsed.comments.filter { $0.split(separator: "=", maxSplits: 1).first?.uppercased() != "DATE" }
            + ["DATE=\(date)"]
        return try OggOpus.mux(OggOpus.read(sealed), tags: CassiniDocument.tagsPacket(comments))
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
