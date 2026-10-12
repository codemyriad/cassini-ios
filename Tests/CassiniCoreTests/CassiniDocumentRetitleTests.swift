@testable import CassiniCore
import Foundation
import Testing

@Suite struct CassiniDocumentRetitleTests {
    let transcript = Transcript([Word("spk_1", 0, 20, "Ciao"), Word("spk_2", 20, 40, "Salve")], language: "it")

    func document(in dir: URL, sourceTags: [String] = ["X_CUSTOM=keep=me", "ARTIST=Anna"], title: String = "Riunione") throws -> URL {
        let bytes = try CassiniDocument.create(silence(sourceTags), transcript: transcript, title: title,
                                               processing: JSONObject([("engine", .string("sherpa-onnx"))]))
        let source = dir.appendingPathComponent("source.opus")
        try Data(bytes).write(to: source)
        return source
    }

    @discardableResult
    func retitle(_ source: URL, _ title: String, existing: CassiniDocument? = nil) throws -> CassiniDocument {
        try CassiniDocument.retitle(source, existing: existing ?? CassiniDocument.read(source), title: title,
                                    target: source.deletingLastPathComponent().appendingPathComponent("target.opus"))
    }

    func titleTags(_ document: CassiniDocument) -> [String] { comments(document) { $0 == "TITLE" } }

    func isManifestTag(_ comment: String) -> Bool {
        let name = CassiniDocument.tagName(comment)
        return name.hasPrefix("CASSINI_PAYLOAD_") && name != "CASSINI_PAYLOAD_SCHEMA" && name != "CASSINI_PAYLOAD_MIME"
    }

    // ports: CassiniDocumentRetitleTest#theTitleChangesInTheManifestAndTheTag
    @Test func theTitleChangesInTheManifestAndTheTag() throws {
        try withTemporaryDirectory { dir in
            let source = try document(in: dir)
            #expect(titleTags(CassiniDocument.read(source)) == ["TITLE=Riunione"])
            let after = try retitle(source, "Standup del lunedì")
            #expect(after.state == .ok)
            #expect(after.warnings.isEmpty)
            #expect(after.title == "Standup del lunedì")
            #expect(titleTags(after) == ["TITLE=Standup del lunedì"])
        }
    }

    // ports: CassiniDocumentRetitleTest#theAudioAndItsDigestAreUnchanged
    @Test func theAudioAndItsDigestAreUnchanged() throws {
        try withTemporaryDirectory { dir in
            let source = try document(in: dir)
            let before = CassiniDocument.read(source)
            let after = try retitle(source, "Nuovo titolo")
            #expect(try OggOpus.read(bytes(source)).digest() == OggOpus.read(bytes(dir.appendingPathComponent("target.opus"))).digest())
            #expect(before.manifest?["integrity"]?.serialized() == after.manifest?["integrity"]?.serialized())
            #expect(before.manifest?["audio"]?.serialized() == after.manifest?["audio"]?.serialized())
        }
    }

    // ports: CassiniDocumentRetitleTest#everythingButTheTitleIsKept
    @Test func everythingButTheTitleIsKept() throws {
        try withTemporaryDirectory { dir in
            let source = try document(in: dir)
            var base = CassiniDocument.read(source)
            base.manifest!["x"] = .object(JSONObject([("keep", .bool(true))]))
            var speakers = base.manifest!["speakers"]!.array!
            var speaker = speakers[0].object!; speaker["pronouns"] = .string("she"); speakers[0] = .object(speaker)
            base.manifest!["speakers"] = .array(speakers)
            let extended = dir.appendingPathComponent("extended.opus")
            try Data(try CassiniDocument.create(try bytes(source), transcript: transcript, title: "Ignored", processing: JSONObject(),
                                                existing: base)).write(to: extended)
            let before = CassiniDocument.read(extended)
            let after = try retitle(extended, "Altro")
            #expect(before.variants.map(\.id) == after.variants.map(\.id))
            #expect(before.variants.map(\.body) == after.variants.map(\.body))
            #expect(before.defaultId == after.defaultId)
            let expected = before.comments.filter { !isManifestTag($0) }.map { $0.hasPrefix("TITLE=") ? "TITLE=Altro" : $0 }
            #expect(after.comments.filter { !isManifestTag($0) } == expected)
            #expect(after.comments.contains("X_CUSTOM=keep=me"))
            #expect(after.comments.contains("ARTIST=Anna"))
            var manifest = before.manifest!
            var meeting = manifest["meeting"]!.object!
            meeting["title"] = .string("Altro")
            manifest["meeting"] = .object(meeting)
            #expect(manifest.serialized() == after.manifest?.serialized())
        }
    }

    // ports: CassiniDocumentRetitleTest#accentsAndQuotesAreKeptExactlyAndTheTitleIsTrimmed
    @Test func accentsAndQuotesAreKeptExactlyAndTheTitleIsTrimmed() throws {
        try withTemporaryDirectory { dir in
            let title = "Riunione “caffè” con l'équipe \"Q3\" — 日本 = ok"
            let after = try retitle(try document(in: dir), "  \(title) \n")
            #expect(after.title == title)
            #expect(titleTags(after) == ["TITLE=\(title)"])
        }
    }

    // ports: CassiniDocumentRetitleTest#anImportedTitleTagThatDiffersEndsEqualToTheManifest
    /** Unlike Android, the seal already writes meeting.title into the source's own TITLE, where it stands. */
    @Test func anImportedTitleTagThatDiffersEndsEqualToTheManifest() throws {
        try withTemporaryDirectory { dir in
            let source = try document(in: dir, sourceTags: ["ALBUM=Calls", "TITLE=voice-memo-0412", "X_CUSTOM=keep=me"], title: "Call with Luca")
            let before = CassiniDocument.read(source)
            #expect(before.title == "Call with Luca")
            #expect(Array(before.comments.prefix(3)) == ["ALBUM=Calls", "TITLE=Call with Luca", "X_CUSTOM=keep=me"])
            // A TITLE that disagrees with the manifest, as an older writer left it, is corrected in place.
            var stale = before
            stale.comments = stale.comments.map { $0.hasPrefix("TITLE=") ? "TITLE=voice-memo-0412" : $0 }
            let after = try retitle(source, "Call with Luca", existing: stale)
            #expect(after.title == "Call with Luca")
            #expect(titleTags(after) == ["TITLE=Call with Luca"])
            #expect(Array(after.comments.prefix(3)) == ["ALBUM=Calls", "TITLE=Call with Luca", "X_CUSTOM=keep=me"])
        }
    }

    // ports: CassiniDocumentRetitleTest#extraTitleTagsAreDroppedAndAMissingOneIsAdded
    @Test func extraTitleTagsAreDroppedAndAMissingOneIsAdded() throws {
        try withTemporaryDirectory { dir in
            let source = try document(in: dir, sourceTags: ["TITLE=one", "title=two", "X_CUSTOM=keep=me"])
            #expect(titleTags(CassiniDocument.read(source)) == ["TITLE=Riunione"])
            var repeated = CassiniDocument.read(source)
            repeated.comments.insert("title=two", at: 1)
            #expect(titleTags(try retitle(source, "Uno", existing: repeated)) == ["TITLE=Uno"])
            var untitled = CassiniDocument.read(source)
            untitled.comments.removeAll { CassiniDocument.tagName($0) == "TITLE" }
            let added = try retitle(source, "Due", existing: untitled)
            #expect(titleTags(added) == ["TITLE=Due"])
            #expect(added.title == "Due")
        }
    }

    // ports: CassiniDocumentRetitleTest#aBlankTitleOrADocumentNotOkIsRefusedAndWritesNothing
    @Test func aBlankTitleOrADocumentNotOkIsRefusedAndWritesNothing() throws {
        try withTemporaryDirectory { dir in
            let source = try document(in: dir)
            let attempts: [() throws -> Void] = [
                { try retitle(source, "  ") },
                { try retitle(source, "Titolo", existing: CassiniDocument.read(source, verify: false)) },
                { try retitle(source, "Titolo", existing: CassiniDocument(state: .plainAudio)) },
            ]
            for attempt in attempts {
                #expect(throws: CassiniError.self) { try attempt() }
                #expect(!FileManager.default.fileExists(atPath: dir.appendingPathComponent("target.opus").path))
            }
        }
    }

    /**
     * [CassiniDocument.read] already checks inside retitle, so a fault shared by the writer and that reader would pass
     * the round trip. The format's own standard-library reader is a separate implementation.
     */
    // ports: CassiniDocumentRetitleTest#theIndependentPythonReaderAcceptsTheResult
    @Test(.enabled(if: Conformance.available && PythonReader.available, "Needs cassini-format's tools and python3"))
    func theIndependentPythonReaderAcceptsTheResult() throws {
        try withTemporaryDirectory { dir in
            try retitle(try document(in: dir), "Verifica è fatta")
            let (status, output) = try PythonReader.run(dir.appendingPathComponent("target.opus"))
            #expect(status == 0, "\(output)")
            let lines = output.components(separatedBy: "\n")
            // The metadata profile verifies every payload digest but never the audio, so its best state is unverified.
            #expect(lines.first == "state: unverified", "\(output)")
            #expect(lines.count > 1 && lines[1].hasPrefix("Verifica è fatta - "), "\(output)")
            #expect(lines.contains { fullMatch($0, #"\s+0 ms\s+spk_1\s+Ciao"#) }, "\(output)")
            #expect(lines.contains { fullMatch($0, #"\s+20 ms\s+spk_2\s+Salve"#) }, "\(output)")
        }
    }

    // ports: CassiniDocumentRetitleTest#aRetitledDocumentReadsBackAndRelabels
    @Test func aRetitledDocumentReadsBackAndRelabels() throws {
        try withTemporaryDirectory { dir in
            let after = try retitle(try document(in: dir), "Verifica")
            let target = dir.appendingPathComponent("target.opus")
            let reread = CassiniDocument.readChecked(target)
            #expect(reread.state == .ok)
            #expect(reread.warnings.isEmpty)
            #expect(reread.variants.map(\.id) == ["words"])
            #expect(reread.selected()?.transcript == transcript)
            #expect(after.manifest?.serialized() == reread.manifest?.serialized())
            // A relabel after a retitle keeps the new title.
            let relabelled = try CassiniDocument.relabel(target, existing: reread, labels: ["spk_1": "Anna"], target: dir.appendingPathComponent("c.opus"))
            #expect(relabelled.title == "Verifica")
            #expect(titleTags(relabelled) == ["TITLE=Verifica"])
        }
    }

    // ports: CassiniDocumentRetitleTest#aConformanceVectorWithUnknownMembersKeepsThem
    @Test(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)))
    func aConformanceVectorWithUnknownMembersKeepsThem() throws {
        try withTemporaryDirectory { dir in
            let source = dir.appendingPathComponent("vector.opus")
            try Data(try Conformance.vector("014-unknown-manifest-member")).write(to: source)
            let before = CassiniDocument.read(source)
            let after = try retitle(source, "Renamed vector")
            #expect(after.state == .ok)
            #expect(after.title == "Renamed vector")
            #expect(after.manifest!.has("cassiniFutureField"))
            #expect(before.variants.map(\.body) == after.variants.map(\.body))
            #expect(titleTags(after) == ["TITLE=Renamed vector"])
        }
    }
}

/** cassini-format's standard-library reader, `tools/cassini-read-pure.py`, run with python3. */
enum PythonReader {
    static let tool = Conformance.directory.appendingPathComponent("../../tools/cassini-read-pure.py").standardized
    static let python = URL(fileURLWithPath: "/usr/bin/env")

    static let available: Bool = {
        guard FileManager.default.fileExists(atPath: tool.path) else { return false }
        return (try? run(arguments: ["python3", "--version"]).status) == 0
    }()

    static func run(_ file: URL) throws -> (status: Int32, output: String) {
        try run(arguments: ["python3", "-I", "-X", "utf8", tool.path, file.path])
    }

    private static func run(arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = python
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }
}
