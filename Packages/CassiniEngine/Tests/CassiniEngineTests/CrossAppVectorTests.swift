import CassiniCore
import CryptoKit
import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The cross-app vectors (parity report risk 6): coordination `ux-draft/cross-app-vectors/`, files every Cassini app
/// must open the same way: `two-versions-default-switched` (from the conformance suite) and `android-written-v1`
/// (written by cassini-android's own writers). Each vector file and `expected.json` are copied byte for byte into
/// `Resources/cross-app-vectors/` and pinned by their SHA-256; a vector's pin is the one the coordination
/// `SHA256.json` publishes. Every expectation `expected.json` lists is checked through the reader
/// (`CassiniDocument.read`, audio verified) and, where the note keeps it, through the import too: the note it makes
/// and the transcript the Note screen shows of each version (`NoteTranscripts.sealed`). A key no check reads fails
/// `everyExpectationIsChecked`, so a new vector cannot pass on the keys the tests happen to know.
@Suite struct CrossAppVectorTests {
    /// SHA-256 of the committed `expected.json`. Update it only together with a byte-identical copy of the shared file.
    static let expectedPin = "ed8248eec38a9df2a05f770469c85ac7c1f9494e4a6b7cf52a0551746627f4b6"
    /// SHA-256 of each committed vector file, as coordination `ux-draft/cross-app-vectors/SHA256.json` gives it.
    static let filePins = [
        "two-versions-default-switched.opus": "d4bffa94eec9481f19668e53ee247f8e5a107402a0740094a0cc29b3252b9f6d",
        "android-written-v1.opus": "29d8a4666d37fe01cee999652470b7c1ba5893af4dbc92a04092005bc777f725",
    ]

    /// The `expect` keys these tests check.
    static let checkedKeys: Set<String> = [
        "classification", "state", "payloadTrust", "audioTrust", "transcriptIds", "defaultTranscriptId", "opensOn",
        "openingWords", "wordCounts", "errors", "warnings", "speakers", "shownLabels", "speakersByWord", "language",
        "title", "tags", "bodyJsonIndented", "provenance",
    ]

    static let folder = "cross-app-vectors"

    static func resource(_ name: String) -> URL? {
        let file = name as NSString
        return Bundle.module.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension, subdirectory: folder)
    }

    /// One entry of `expected.json`.
    struct Vector: Sendable, CustomTestStringConvertible {
        let id: String
        let file: String
        let expect: JSONObject
        var testDescription: String { id }

        var url: URL? { CrossAppVectorTests.resource(file) }
        func strings(_ key: String) -> [String]? { expect[key]?.array?.compactMap(\.string) }
    }

    /// The vectors of `expected.json`; empty when it is missing or does not parse (the pin test then fails).
    static let vectors: [Vector] = {
        guard let url = resource("expected.json"), let data = try? Data(contentsOf: url),
              let index = try? JSON.parseObject(String(decoding: data, as: UTF8.self)) else { return [] }
        return index.keys.sorted().compactMap { id in
            guard let entry = index[id]?.object, let file = entry["file"]?.string, let expect = entry["expect"]?.object else { return nil }
            return Vector(id: id, file: file, expect: expect)
        }
    }()

    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    @Test func theCopiesAreTheCommittedVectors() throws {
        let expected = try Data(contentsOf: try #require(Self.resource("expected.json"), "Resources/cross-app-vectors/expected.json is missing"))
        #expect(Self.sha256(expected) == Self.expectedPin)
        #expect(Self.vectors.map(\.file).sorted() == Self.filePins.keys.sorted(), "every vector parses and every file is pinned")
        for vector in Self.vectors {
            let data = try Data(contentsOf: try #require(vector.url, "Resources/cross-app-vectors/\(vector.file) is missing"))
            #expect(Self.sha256(data) == Self.filePins[vector.file], "\(vector.file)")
        }
    }

    @Test(arguments: vectors)
    func everyExpectationIsChecked(_ vector: Vector) {
        #expect(Set(vector.expect.keys).subtracting(Self.checkedKeys).sorted() == [], "add a check for these keys")
    }

    // MARK: - Reader

    @Test(arguments: vectors)
    func theReaderObservesWhatTheVectorExpects(_ vector: Vector) throws {
        let document = CassiniDocument.read(try #require(vector.url))
        let expect = vector.expect
        let reported = document.warnings + document.variants.compactMap(\.error)
        #expect(document.state.rawValue == expect["state"]?.string, "\(document.state) \(reported)")
        #expect(Self.classification(document.state) == expect["classification"]?.string, "\(document.state)")
        #expect(Self.payloadTrust(document.state) == expect["payloadTrust"]?.string, "\(document.state)")
        #expect(document.variants.map(\.id) == vector.strings("transcriptIds"))
        #expect(document.defaultId == expect["defaultTranscriptId"]?.string)
        let counts = try #require(expect["wordCounts"]?.object)
        var actual: [String: Int64] = [:]
        for variant in document.variants { if let transcript = variant.transcript { actual[variant.id] = Int64(transcript.words.count) } }
        #expect(actual == Dictionary(uniqueKeysWithValues: try counts.keys.map { ($0, try counts.number($0)) }))
        #expect(document.variants.compactMap(\.error) == [], "errors: \(expect["errors"] ?? .null)")
        #expect(document.warnings == [], "warnings: \(expect["warnings"] ?? .null)")
        #expect(expect["errors"]?.array?.isEmpty == true && expect["warnings"]?.array?.isEmpty == true,
                "a vector naming errors or warnings needs their codes checked here")

        let opening = try #require(vector.strings("openingWords"))
        let opened = try #require(document.selected(), "the reader opens a variant")
        #expect(opened.id == expect["opensOn"]?.string)
        #expect(opened.transcript?.words.prefix(opening.count).map(\.text) == opening)
        let portable = try #require(PortableTranscript(document))
        #expect(portable.selected?.portableID == expect["opensOn"]?.string, "the note's view of the document")

        if let audio = expect["audioTrust"]?.string { #expect(Self.audioTrust(document.state) == audio, "\(document.state)") }
        if let speakers = expect["speakers"]?.array {
            // The manifest's speakers, in order: each id with its label as stored (D47), whatever else it carries.
            let actual = (document.manifest?["speakers"]?.array ?? []).map { [$0.object?["id"]?.string, $0.object?["label"]?.string] }
            #expect(actual == speakers.map { [$0.object?["id"]?.string, $0.object?["label"]?.string] })
        }
        if let byWord = expect["speakersByWord"]?.object {
            for id in byWord.keys {
                let words = document.variants.first { $0.id == id }?.transcript?.words
                #expect(words?.map(\.speaker) == byWord[id]?.array?.compactMap(\.string), "\(id)")
            }
        }
        if let languages = expect["language"]?.object {
            for id in languages.keys {
                let variant = document.variants.first { $0.id == id }
                #expect(variant?.transcript?.language == languages[id]?.string, "\(id): the body's language")
                #expect(variant?.descriptor["language"]?.string == languages[id]?.string, "\(id): the descriptor's language")
            }
        }
        if let title = expect["title"]?.string { #expect(document.title == title) }
        if let tags = expect["tags"]?.object {
            for name in tags.keys {
                let values = document.comments.compactMap { comment -> String? in
                    guard let cut = comment.firstIndex(of: "="), comment[..<cut].uppercased() == name else { return nil }
                    return String(comment[comment.index(after: cut)...])
                }
                if let value = tags[name]?.string { #expect(values == [value], "\(name)") } else { #expect(values == [], "no \(name) tag") }
            }
        }
        if let indented = expect["bodyJsonIndented"]?.bool {
            // Android writes its bodies indented, one of the deviations every reader accepts.
            for variant in document.variants {
                #expect((variant.body?.contains("\n") ?? false) == indented, "\(variant.id)")
            }
        }
        if let provenance = expect["provenance"]?.object {
            let speechToText = document.manifest?["provenance"]?.object?["speechToText"]?.object
            for id in provenance.keys {
                let actual = speechToText?[id]?.object
                for (key, value) in try #require(provenance[id]?.object).pairs {
                    if key == "hasXSpeakerDiarization" {
                        #expect((actual?["x-speakerDiarization"]?.object != nil) == value.bool, "\(id)")
                    } else {
                        #expect(actual?[key] == value, "\(id) \(key)")
                    }
                }
            }
        }
    }

    // MARK: - Import

    @Test(arguments: vectors)
    func anImportOpensOnTheVersionTheVectorNames(_ vector: Vector) async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-cross-app-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let inputs = base.appendingPathComponent("inputs")
        try FileManager.default.createDirectory(at: inputs, withIntermediateDirectories: true)
        let input = inputs.appendingPathComponent(vector.file)
        try FileManager.default.copyItem(at: try #require(vector.url), to: input)
        let store = try NoteStore(root: base.appendingPathComponent("notes"))
        let storage = FakeStorage()
        let service = ImportService(notes: store, files: CoordinatedFileImporter(storage: storage), audio: FakeAudioProcessing(),
                                    storage: storage, clock: FakeClock())

        let outcome = try await service.importFile(input, fallbackTitle: ImportTitles.fallbackTitle)
        guard case .created(let id) = outcome else { Issue.record("expected a new note, got \(outcome)"); return }
        let note = try #require(await store.note(id))
        let expect = vector.expect

        #expect(note.origin == .importedDocument)
        #expect(note.document?.state.rawValue == expect["state"]?.string)
        #expect(note.document?.warnings == [] && note.document?.unavailableVariants == [:])
        #expect((note.versions ?? []).map { $0.portableID ?? "made here" } == vector.strings("transcriptIds"),
                "every variant is a version, in file order")
        let shown = try #require(note.versions?.first { $0.id == note.selectedVersionID }, "the note shows a version")
        #expect(shown.portableID == expect["opensOn"]?.string)
        let counts = try #require(expect["wordCounts"]?.object)
        for version in note.versions ?? [] {
            let id = try #require(version.portableID)
            #expect(Int64(version.segments.flatMap(\.words).count) == (try counts.number(id)), "\(id)")
        }

        let opening = try #require(vector.strings("openingWords"))
        let screen = NoteTranscripts.sealed(note).turns.flatMap(\.words).map(\.text)
        #expect(Array(screen.prefix(opening.count)) == opening, "the Note screen opens on \(opening.joined(separator: " "))")

        if let title = expect["title"]?.string { #expect(note.title == title) }
        if let languages = expect["language"]?.object {
            for version in note.versions ?? [] {
                let id = try #require(version.portableID)
                #expect(version.language == languages[id]?.string, "\(id)")
            }
        }
        if let byWord = expect["speakersByWord"]?.object {
            for version in note.versions ?? [] {
                let id = try #require(version.portableID)
                let speakers = version.segments.flatMap { segment in segment.words.map { _ in segment.speakerID } }
                #expect(speakers == byWord[id]?.array?.map(\.string), "\(id)")
            }
        }
        if let shown = expect["shownLabels"]?.object {
            // Each version as the Note screen shows it: stored labels as stored, in any UI language (D47).
            for version in note.versions ?? [] {
                let id = try #require(version.portableID)
                var showing = note
                showing.transcript = version.segments
                showing.speakers = version.speakers
                showing.selectedVersionID = version.id
                var labels: [String] = []
                for turn in NoteTranscripts.sealed(showing).turns {
                    let label = Self.label(turn.name)
                    if !labels.contains(label) { labels.append(label) }
                }
                #expect(labels == shown[id]?.array?.compactMap(\.string), "\(id)")
            }
        }
    }

    /// The text a speaker header shows.
    private static func label(_ name: SpeakerName) -> String {
        switch name {
        case .named(let name): name
        case .placeholder(_, let label): label
        case .unknown: "Unknown speaker"
        }
    }

    /// The audio trust of the conformance suite's vocabulary for the reader's `state`: the audio digest matches in
    /// `ok`, is absent or unchecked in `unverified`, differs in `stale-audio` (cassini-format `spec/conformance/index.json`).
    private static func audioTrust(_ state: DocumentState) -> String? {
        switch state {
        case .ok: "verified"
        case .unverified: "unverified"
        case .staleAudio: "mismatched"
        case .plainAudio: "not-applicable"
        case .unknownFormat, .invalidMetadata, .unreadable: nil
        }
    }

    // The reader reports trust through its state alone: a payload that fails its digest makes the file
    // invalid-cassini-metadata, and the audio check decides between ok, unverified and stale-audio. These map a state to
    // the conformance suite's vocabulary (cassini-format `spec/conformance/index.json`), where every state with a
    // transcript keeps a verified payload, unverified and stale-audio included. A state the suite gives more than one
    // value for (invalid-cassini-metadata: payload unverified or mismatched) is nil, so a vector expecting it fails here
    // until the reader reports the detail.

    /// The classification of the conformance suite's vocabulary for the reader's `state`.
    private static func classification(_ state: DocumentState) -> String? {
        switch state {
        case .ok, .unverified, .staleAudio: "cassini"
        case .plainAudio: "plain-audio"
        case .unknownFormat: "unsupported-version"
        case .invalidMetadata: "damaged-metadata"
        case .unreadable: nil
        }
    }

    /// The payload trust of the conformance suite's vocabulary for the reader's `state`.
    private static func payloadTrust(_ state: DocumentState) -> String? {
        switch state {
        case .ok, .unverified, .staleAudio: "verified"
        case .plainAudio: "not-applicable"
        case .unknownFormat: "unverified"
        case .invalidMetadata, .unreadable: nil
        }
    }
}
