import CassiniCore
import CryptoKit
import Foundation
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The shared language-tag cases of D53.2 Q2: coordination `ux-draft/library-vectors/language-tag/cases.json`, copied
/// byte for byte into `Resources/language-tag/` and pinned by its SHA-256. A variant's language is the language of the
/// recognizer run that made its words, the same in the word body, the descriptor and the processing step; Parakeet
/// writes `und`, Apple Speech the locale that ran; derived versions keep the language of their words and imported ones
/// their stored value. Run cases of the recognizers iOS has go through the real job (twice for a `laterRun`), the
/// version history and the export, including bundled Whistle. iOS leaves an empty language out
/// of the body and the descriptor, which the cases allow. Android pins the Parakeet case with
/// `TranscriptionJobTest#theRecognizersLanguageIsWrittenAlikeInBodyDescriptorAndProvenance`, ported in
/// `TranscriptionJobParakeetTests`.
@Suite struct LanguageTagVectorTests {
    /// SHA-256 of the committed `cases.json`. Update it only together with a byte-identical copy of the shared file.
    static let pinned = "2ff6a3cfe5e358b7a5c604bb84de67474fbcfca930c7379bd9ba5ea14c9e39c3"

    static let url = Bundle.module.url(forResource: "cases", withExtension: "json", subdirectory: "language-tag")

    /// The cases' file as JSON; empty when it is missing or does not parse (the pin test then fails).
    static func cases() -> [String: Any] {
        guard let url, let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        return object
    }

    /// A string, or nil for JSON null and a missing key.
    private static func string(_ value: Any?) -> String? { value as? String }

    /// A recognizer run of a case.
    struct Run: Sendable {
        let engine: String
        let picker: String?
        let ranLocale: String?

        init?(_ value: Any?) {
            guard let run = value as? [String: Any], let engine = run["engine"] as? String else { return nil }
            self.engine = engine
            picker = LanguageTagVectorTests.string(run["picker"]); ranLocale = LanguageTagVectorTests.string(run["ranLocale"])
        }
    }

    struct Writer: Sendable, CustomTestStringConvertible {
        enum Origin: Sendable { case run(Run, later: Run?), imported(stored: String?) }
        enum Provenance: Sendable, Equatable { case value(String), absent, unchecked }
        let id: String
        let origin: Origin
        let derivation: String
        let body: String
        let descriptor: String
        let provenance: Provenance
        var testDescription: String { id }
    }

    struct Reader: Sendable, CustomTestStringConvertible {
        let id: String
        let stored: String?
        let known: Bool
        let display: String?
        var testDescription: String { id }
    }

    static let writers: [Writer] = ((cases()["writer"] as? [[String: Any]]) ?? []).compactMap { entry in
        guard let id = entry["id"] as? String, let origin = entry["origin"] as? [String: Any],
              let derivation = entry["derivation"] as? String, let expect = entry["expect"] as? [String: Any],
              let body = expect["body"] as? String, let descriptor = expect["descriptor"] as? String else { return nil }
        let parsed: Writer.Origin
        if let run = Run(origin["run"]) {
            parsed = .run(run, later: Run(origin["laterRun"]))
        } else if let imported = origin["imported"] as? [String: Any] {
            parsed = .imported(stored: string(imported["stored"]))
        } else {
            return nil
        }
        let provenance: Writer.Provenance = switch expect["provenance"] {
        case nil: .unchecked
        case let value as String: .value(value)
        default: .absent
        }
        return Writer(id: id, origin: parsed, derivation: derivation, body: body, descriptor: descriptor, provenance: provenance)
    }

    static let readers: [Reader] = ((cases()["reader"] as? [[String: Any]]) ?? []).compactMap { entry in
        guard let id = entry["id"] as? String, let known = entry["known"] as? Bool else { return nil }
        return Reader(id: id, stored: string(entry["stored"]), known: known, display: string(entry["display"]))
    }

    @Test func theCopyIsTheCommittedVector() throws {
        let data = try Data(contentsOf: try #require(Self.url, "Resources/language-tag/cases.json is missing"))
        #expect(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == Self.pinned)
        let cases = Self.cases()
        #expect(Self.writers.count == ((cases["writer"] as? [Any])?.count ?? -1), "every writer case parses")
        #expect(Self.readers.count == ((cases["reader"] as? [Any])?.count ?? -1), "every reader case parses")
        #expect(Self.writers.count == 24 && Self.readers.count == 9)
    }

    // MARK: - Reader

    @Test(arguments: readers)
    func aReaderShowsALanguageOnlyWhenItIsKnown(_ c: Reader) {
        #expect((TranscriptLanguage.known(c.stored) != nil) == c.known)
        #expect(TranscriptLanguage.known(c.stored) == c.display)
        var note = Note(title: "Note")
        note.language = c.stored ?? ""
        #expect(DocumentInfoFacts.of(note, provenance: nil, fileBytes: nil, speechModels: [:]).language == c.display,
                "Document info")
    }

    // MARK: - Writer

    /// The pure rule over every run case, Whistle's included: what the recognizer reports, else `und`.
    @Test(arguments: writers.filter { if case .run = $0.origin { true } else { false } })
    func aRunWritesTheLanguageItRanIn(_ c: Writer) throws {
        guard case .run(let run, _) = c.origin else { return }
        let reported = run.engine == "parakeet" ? nil : run.ranLocale
        #expect(TranscriptLanguage.ofRun(reported: reported) == c.body)
        #expect(c.body == c.descriptor && (c.derivation == "passageEdit" || c.provenance == .value(c.body)),
                "the case states one language in all three places")
    }

    @Test(arguments: writers)
    func theExportCarriesTheLanguageOfTheWords(_ c: Writer) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("cassini-language-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var note: Note
        let original: URL
        let provenance: any ProvenanceStoring
        var root: URL?
        switch c.origin {
        case .run(let run, let later):
            let initial: (any Transcribing)?
            if run.engine == "parakeet" { initial = WindowedTranscriber() }
            else if run.engine == "whistle" { initial = WhistleJobTestTranscriber(language: run.ranLocale) }
            else { initial = nil }
            let h = try await TranscriptionJobTests.Harness(engine: initial)
            root = h.root
            h.transcriber.ranLocale = run.ranLocale
            #expect(await h.run(language: run.picker ?? "").outcome == .done)
            note = try #require(await h.note())
            #expect(h.provenance(of: note)?.language == c.body, "the run's record")
            #expect(note.versions?.last?.language == c.body, "the run's version")
            if let later {
                // Another run over the same recording with other words, then the first run's version shown again.
                let first = try #require(note.versions?.last?.id)
                let other = TranscriptionJobTests.ScriptedTranscriber(script: Self.otherWords, total: 70, status: .ready)
                other.ranLocale = later.ranLocale
                let parakeet = WindowedTranscriber()
                parakeet.word = "v"
                let engine: any Transcribing
                if later.engine == "parakeet" { engine = parakeet }
                else if later.engine == "whistle" { engine = WhistleJobTestTranscriber(language: later.ranLocale) }
                else { engine = other }
                #expect(await h.run(language: later.picker ?? "", using: engine).outcome == .done)
                let shown = try #require(await h.note())
                #expect(shown.language == TranscriptLanguage.ofRun(reported: later.engine == "parakeet" ? nil : later.ranLocale),
                        "the later run wrote its own language")
                note = try #require(try await h.notes.mutate(h.noteID) { $0.selectVersion(first) })
                #expect(note.language == c.body, "selecting the first run's version brings its language back")
            }
            attribute(&note, turns: [("a", 0, 35), ("b", 35, 70)])
            original = h.audioURL
            provenance = h.provenanceFiles
        case .imported(let stored):
            let words = ["uno", "due", "tre", "quattro"].enumerated().map { index, text in
                Word(index.isMultiple(of: 2) ? "a" : "b", Int64(index * 500), Int64(index * 500 + 400), text)
            }
            var bytes = try CassiniDocument.create(ImportFixtures.opus(), transcript: Transcript(words, language: stored ?? ""),
                                                   title: "Importata", processing: JSONObject([("engine", .string("gocassini"))]),
                                                   speakerLabels: ["a": "Ada", "b": "Bea"])
            // iOS's writer leaves an empty language out; the case is the member present and empty, as Android's
            // descriptor writes it.
            if stored == "" { bytes = try Self.withEmptyLanguage(bytes) }
            original = folder.appendingPathComponent("source.opus")
            try Data(bytes).write(to: original)
            let portable = try #require(PortableTranscript.read(from: original))
            note = ImportedNote.make(id: UUID(), displayName: "source.opus", fallbackTitle: "F", sha256: "s",
                                     importedAt: Date(), audio: ImportedAudio(filename: "source.opus", duration: 2),
                                     document: portable)
            #expect(note.language == (stored ?? ""), "the stored value, as it is")
            provenance = FakeProvenance()
        }
        defer { if let root { try? FileManager.default.removeItem(at: root) } }
        let derivedFrom = note.language

        switch c.derivation {
        case "fresh":
            break
        case "passageEdit":
            let passage = try #require(note.transcript.first)
            #expect(note.revisePassage(passage, to: passage.revised(text: passage.text + " corretto", speakerID: passage.speakerID,
                                                                     speakers: note.speakers ?? []),
                                       stamp: VersionStamp(date: Date())) == .saved)
        case "merge":
            let ids = (note.speakers ?? []).map(\.id)
            try #require(ids.count >= 2)
            note.mergeSpeaker(ids[1], into: ids[0])
            #expect(note.versions?.last?.kind == .mergedSpeakers)
        case "reassign":
            attribute(&note, turns: [("x", 0, 1), ("y", 1, 70)])
            #expect(note.versions?.last?.kind == .speakerAnalysis)
        default:
            Issue.record("unknown derivation \(c.derivation)")
        }
        #expect(note.language == derivedFrom, "a derived version keeps the language of the words it came from")
        #expect(note.versions?.first { $0.id == note.selectedVersionID }?.language == derivedFrom, "the shown version")

        let output = try await PortableExportService(audio: FakeAudioProcessing(duration: 70, opensAnyFile: true),
                                                     provenance: provenance, unassignedLabel: "Unknown speaker")
            .export(note, original: original, playable: original, into: folder, filename: "export")
        let document = CassiniDocument.read(output)
        #expect(document.state == .ok)
        let id = try #require(document.defaultId)
        let variant = try #require(document.variants.first { $0.id == id })
        let body = try JSON.parseObject(try #require(variant.body))
        expect(body["language"]?.string, c.body, "body")
        expect(variant.descriptor["language"]?.string, c.descriptor, "descriptor")
        let step = document.manifest?["provenance"]?.object?["speechToText"]?.object?[id]?.object
        switch c.provenance {
        case .value(let value): #expect(step?["language"]?.string == value, "provenance")
        case .absent: #expect(step != nil && step?["language"] == nil, "a step of no run of this app names no language")
        case .unchecked: break
        }
    }

    /// Two runs in two languages, Apple Speech's `it-IT` then Parakeet's `und`: each exported variant carries its own
    /// run's language in its body, its descriptor and its step, the earlier run's too.
    @Test func everyVariantCarriesTheLanguageOfItsOwnRun() async throws {
        let h = try await TranscriptionJobTests.Harness()
        defer { try? FileManager.default.removeItem(at: h.root) }
        h.transcriber.ranLocale = "it-IT"
        #expect(await h.run(language: "it").outcome == .done)
        let parakeet = WindowedTranscriber()
        parakeet.word = "v"
        #expect(await h.run(language: "it", using: parakeet).outcome == .done)
        let note = try #require(await h.note())
        #expect(note.versions?.map(\.language) == ["it-IT", "und"])

        let folder = h.root.appendingPathComponent("export", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let output = try await PortableExportService(audio: FakeAudioProcessing(duration: 70, opensAnyFile: true),
                                                     provenance: h.provenanceFiles, unassignedLabel: "Unknown speaker")
            .export(note, original: h.audioURL, playable: h.audioURL, into: folder, filename: "export")
        let document = CassiniDocument.read(output)
        #expect(document.state == .ok)
        let steps = document.manifest?["provenance"]?.object?["speechToText"]?.object
        let languages = try document.variants.map { variant in
            let body = try JSON.parseObject(try #require(variant.body))["language"]?.string
            let step = steps?[variant.id]?.object?["language"]?.string
            #expect(body == variant.descriptor["language"]?.string && body == step, "\(variant.id): one language in three places")
            return body
        }
        #expect(languages == ["it-IT", "und"], "the earlier run's variant keeps its run's language")
        #expect(document.variants.last?.id == document.defaultId)
    }

    /// Words other than the scripted runs' "w0"…"w69" at the same times, so that a later run's record is another one.
    static let otherWords: [TranscriptSegment] = TranscriptionJobTests.ScriptedTranscriber.seventySeconds.map { segment in
        var other = segment
        other.text = segment.text.replacingOccurrences(of: "w", with: "v")
        other.words = segment.words.map { word in var renamed = word; renamed.text = word.text.replacingOccurrences(of: "w", with: "v"); return renamed }
        return other
    }

    /// `bytes` (one variant, `words`) with `"language": ""` written in its word body and its descriptor.
    static func withEmptyLanguage(_ bytes: [UInt8]) throws -> [UInt8] {
        let document = CassiniDocument.read(bytes)
        var manifest = try #require(document.manifest)
        let variant = try #require(document.variants.first { $0.id == "words" })
        var body = try JSON.parseObject(try #require(variant.body))
        body["language"] = .string("")
        let bodyPrefix = "CASSINI_TX_WORDS_PAYLOAD_", manifestPrefix = "CASSINI_PAYLOAD_"
        let (ref, bodyTags) = try CassiniPayload.encode(prefix: bodyPrefix, mime: CassiniPayload.wordMime, text: body.serialized())
        manifest["transcripts"] = .array(try manifest.array("transcripts").map { value in
            guard var descriptor = value.object, descriptor["id"]?.string == "words" else { return value }
            descriptor["language"] = .string("")
            descriptor["payloadRef"] = .object(ref)
            return .object(descriptor)
        })
        let manifestTags = try CassiniPayload.encode(prefix: manifestPrefix, mime: CassiniPayload.mime,
                                                     text: manifest.serialized()).tags
        // A payload's own tags: its prefix, then a member name or a chunk number (`CASSINI_PAYLOAD_SCHEMA` is not one).
        let members: Set<Substring> = ["MIME", "ENCODING", "CHUNK_COUNT", "SHA256", "RAW_BYTES", "GZIP_BYTES"]
        func isPayload(_ comment: String, _ prefix: String) -> Bool {
            guard comment.hasPrefix(prefix) else { return false }
            let name = comment.dropFirst(prefix.count).prefix { $0 != "=" }
            return members.contains(name) || name.allSatisfy(\.isNumber)
        }
        let kept = document.comments.filter { !isPayload($0, bodyPrefix) && !isPayload($0, manifestPrefix) }
        let out = ArraySink()
        _ = try OggOpus.rewrite(ArraySource(bytes), tags: CassiniDocument.tagsPacket(kept + bodyTags + manifestTags), to: out)
        let written = CassiniDocument.read(out.bytes)
        try #require(written.state == .ok, "the fixture still verifies: \(written.state) \(written.warnings)")
        let writtenVariant = try #require(written.variants.first)
        try #require(writtenVariant.descriptor["language"]?.string == "")
        try #require(try JSON.parseObject(try #require(writtenVariant.body))["language"]?.string == "")
        return out.bytes
    }

    /// An expected `""` is met by the member left out (as iOS writes it) or empty; any other value exactly.
    private func expect(_ actual: String?, _ expected: String, _ place: String,
                        sourceLocation: SourceLocation = #_sourceLocation) {
        if expected.isEmpty {
            #expect(actual == nil, "\(place): iOS leaves an empty language out", sourceLocation: sourceLocation)
        } else {
            #expect(actual == expected, "\(place)", sourceLocation: sourceLocation)
        }
    }

    /// Speakers told apart over the note's words, as the speaker step gives them.
    private func attribute(_ note: inout Note, turns: [(String, Double, Double)]) {
        note.applySpeakerAnalysis(turns: turns.map { SpeakerTurn(speakerID: $0.0, start: $0.1, end: $0.2) }, matches: [:],
                                  voiceNames: [:], autoName: false, stamp: VersionStamp(date: Date()))
    }
}
