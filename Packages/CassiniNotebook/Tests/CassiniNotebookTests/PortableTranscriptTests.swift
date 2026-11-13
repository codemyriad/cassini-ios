import Foundation
import Testing
import CassiniCore
@testable import CassiniNotebook

@Test func portableImportPreservesVerifiedWordsAndOriginal() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".opus")
    defer { try? FileManager.default.removeItem(at: url) }
    let head = Array("OpusHead".utf8) + [1, 1, 0, 0, 0x80, 0xBB, 0, 0, 0, 0, 0]
    let tags = CassiniDocument.tagsPacket(["X_CUSTOM=keep=me"])
    let audio = try OggOpus.mux(OggOpus.Stream(head: head, tags: tags, audio: [[0xF8, 0xFF, 0xFE]], finalGranule: 960, validFraming: true), tags: tags)
    let transcript = Transcript([Word("spk_1", 0, 15, "Hello"), Word("spk_2", 5, 20, "there.")], language: "en")
    let original = Data(try CassiniDocument.create(audio, transcript: transcript, title: "Portable note", processing: JSONObject(), speakerLabels: ["spk_1": "Alex", "spk_2": "Sam"]))
    try original.write(to: url)
    let imported = try #require(PortableTranscript.read(from: url))
    #expect(imported.title == "Portable note")
    #expect(imported.language == "en")
    #expect(imported.segments.map(\.text) == ["Hello", "there."])
    #expect(imported.segments.map(\.speaker) == ["Alex", "Sam"])
    #expect(imported.segments.map(\.start) == [0, 0.005])
    #expect(try Data(contentsOf: url) == original)
    #expect(imported.speakers.map(\.id) == ["spk_1", "spk_2"])
    var note = Note(title: "Renamed portable note")
    note.transcript = imported.segments; note.speakers = imported.speakers
    note.renameSpeaker("spk_1", name: "Alice")
    note.transcript[1].text = "Edited reply"; note.transcript[1].words = []
    let output = url.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".opus")
    defer { try? FileManager.default.removeItem(at: output) }
    try PortableTranscript.export(note: note, opus: url, destination: output, unassignedLabel: "Unknown speaker")
    let document = CassiniDocument.read(output)
    #expect(document.state == .ok)
    #expect(document.title == note.title)
    #expect(document.variants.count == 2)
    #expect(document.variants.first?.transcript == transcript)
    #expect(document.speakerLabel("spk_1") == "Alice")
    #expect(document.selected()?.transcript?.words.map(\.text) == ["Hello", "Edited", "reply"])
    #expect(try OggOpus.scan(output).digest() == OggOpus.scan(url).digest())
    #expect(try Data(contentsOf: url) == original)
    #expect(PortableTranscript.read(from: output)?.versions.count == 2)
    try Data(audio).write(to: url)
    #expect(PortableTranscript.read(from: url) == nil)
    try Data("invalid".utf8).write(to: url)
    #expect(PortableTranscript.read(from: url) == nil)
}

@Suite struct PortableReadTests {
    private func read(_ bytes: [UInt8]) -> PortableTranscript? { PortableTranscript(CassiniDocument.read(bytes)) }

    @Test func plainAudioIsNotADocument() throws {
        #expect(read(try PortableFixtures.silence()) == nil)
    }

    @Test func aVerifiedDocumentKeepsItsMeeting() throws {
        let bytes = try PortableFixtures.document([Word("S1", 100, 600, "Hello.")], title: "Session", labels: ["S1": "Ada"])
        let portable = try #require(read(bytes))
        #expect(portable.state == .ok)
        #expect(portable.title == "Session")
        #expect(portable.language == "it")
        #expect(portable.duration == 1)
        #expect(portable.createdAt != nil)
        #expect(portable.speakers == [NoteSpeaker(id: "S1", name: "Ada", colourIndex: 0, provenance: .source)])
        let meetingID = try #require(portable.meetingID, "Document info shows the meeting id")
        #expect(meetingID.hasPrefix("mtg_"))
        #expect(portable.info == DocumentInfo(state: .ok, meetingID: meetingID))
    }

    @Test func theFirstReadableVariantStandsInForAnUnavailableDefault() throws {
        let first = try PortableFixtures.document([Word("S1", 0, 500, "first")], title: "Two")
        let second = try CassiniDocument.create(first, transcript: Transcript([Word("S1", 0, 500, "second")], language: "en"),
                                                title: "Two", processing: JSONObject(), existing: CassiniDocument.read(first))
        let sealed = CassiniDocument.read(second)
        let defaultID = try #require(sealed.defaultId)
        #expect(defaultID != "words")
        let prefix = "CASSINI_TX_" + defaultID.uppercased().replacingOccurrences(of: "-", with: "_") + "_PAYLOAD_000="
        let broken = try PortableFixtures.rewritingComments(second) { $0.uppercased().hasPrefix(prefix) ? nil : $0 }

        let portable = try #require(read(broken))

        #expect(portable.hasTranscript)
        #expect(portable.versions.map(\.portableID) == ["words"])
        #expect(portable.segments.map(\.text) == ["first"])
        #expect(portable.language == "it")
        #expect(portable.unavailableVariants.keys.sorted() == [defaultID])
        #expect(portable.unavailableVariants[defaultID]?.isEmpty == false)
    }

    @Test func brokenMetadataIsADocumentWithoutATranscript() throws {
        let bytes = try PortableFixtures.document([Word("S1", 0, 200, "a"), Word("S1", 300, 500, "test")], title: "Test")
        let broken = try PortableFixtures.rewritingComments(bytes) { $0.hasPrefix("CASSINI_PROFILE=") ? "CASSINI_PROFILE=other" : $0 }
        let portable = try #require(read(broken))
        #expect(portable.state == .invalidMetadata)
        #expect(!portable.hasTranscript)
        #expect(portable.versions.isEmpty)
        #expect(portable.title.isEmpty)
    }

    @Test func anUnreadableFileIsADocumentWithItsError() throws {
        let missing = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).opus")
        let portable = try #require(PortableTranscript.read(from: missing))
        #expect(portable.state == .unreadable)
        #expect(!portable.warnings.isEmpty)
        #expect(!portable.hasTranscript)
    }

    @Test func theVendorComesFromTheOpusTags() throws {
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("doc.opus")
        try Data(try PortableFixtures.document([Word("S1", 0, 500, "hello")], title: "T")).write(to: url)
        #expect(PortableTranscript.read(from: url)?.vendor == CassiniDocument.vendor)
    }
}

@Suite(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)))
struct PortableConformanceImportTests {
    private func imported(_ vector: String) throws -> PortableTranscript {
        try #require(PortableTranscript.read(from: Conformance.vector(vector)))
    }

    @Test func aMissingChunkLeavesTheTranscriptUnavailableAndSaysWhy() throws {
        let portable = try imported("006-missing-chunk")
        #expect(portable.state == .ok)
        #expect(!portable.hasTranscript)
        #expect(portable.unavailableVariants["raw-asr"]?.contains("chunk-missing") == true)
    }

    @Test func aChunkCountCopyThatDisagreesStillGivesTheTranscript() throws {
        let portable = try imported("007-chunk-count-too-high")
        #expect([.ok, .unverified].contains(portable.state))
        #expect(portable.selected?.segments.flatMap(\.words).count == 900)
        #expect(portable.warnings.contains { $0.contains("tag-manifest-disagreement") })
    }

    @Test func staleAudioKeepsItsTranscriptAndItsWarnings() throws {
        let portable = try imported("010-stale-audio")
        #expect(portable.state == .staleAudio)
        #expect(portable.selected?.segments.flatMap(\.words).count == 900)
        #expect(portable.warnings.contains("audio-digest-mismatch"))
        #expect(portable.info.state == .staleAudio)
        #expect(DocumentTrust(portable.state) == .audioChanged)
    }

    @Test func aNewerFormatGivesNoTranscript() throws {
        let portable = try imported("015-unknown-major-version")
        #expect(portable.state == .unknownFormat)
        #expect(!portable.hasTranscript)
    }

    @Test func aDanglingTranscriptIdIsIgnored() throws {
        let portable = try imported("017-dangling-transcript-id")
        #expect([.ok, .unverified].contains(portable.state))
        #expect(portable.versions.map(\.portableID) == ["raw-asr"])
        #expect(portable.selected?.segments.flatMap(\.words).count == 3)
    }

    @Test func exportFromAStaleSourceSealsAFreshDocumentOverTheSameAudio() throws {
        let source = Conformance.vector("010-stale-audio")
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("export.opus")
        let portable = try imported("010-stale-audio")
        var note = Note(title: "Renamed meeting")
        note.language = "it-IT"
        note.transcript = portable.segments
        note.speakers = portable.speakers
        let before = try Data(contentsOf: source)

        try PortableTranscript.export(note: note, opus: source, destination: output, unassignedLabel: "Unknown speaker")

        let exported = CassiniDocument.read(output)
        #expect(exported.state == .ok)
        #expect(exported.title == "Renamed meeting")
        #expect(exported.variants.count == 1)
        #expect(exported.selected()?.transcript?.language == "it-IT")
        #expect(exported.selected()?.transcript?.words.count == 900)
        #expect(exported.comments.filter { $0.uppercased().hasPrefix("TITLE=") } == ["TITLE=Renamed meeting"])
        #expect(try OggOpus.scan(output).digest() == OggOpus.scan(source).digest())
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func exportFromAnUnverifiedSourceWorks() throws {
        let source = Conformance.vector("017-dangling-transcript-id")
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("export.opus")
        var note = Note(title: "Edited")
        note.transcript = try imported("017-dangling-transcript-id").segments
        try PortableTranscript.export(note: note, opus: source, destination: output, unassignedLabel: "Unknown speaker")
        #expect(CassiniDocument.read(output).state == .ok)
    }
}

@Suite struct PortableExportTests {
    @Test func aNoteWithoutWordsIsRefused() throws {
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("audio.opus")
        try Data(try PortableFixtures.silence()).write(to: source)
        #expect(throws: PortableExportError.noTranscript) {
            try PortableTranscript.export(note: Note(title: "Empty"), opus: source, destination: directory.appendingPathComponent("out.opus"),
                                          unassignedLabel: "Unknown speaker")
        }
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("out.opus").path))
    }

    /// The note's language goes into the variant as it is: no `Locale` rewriting (D53.2).
    @Test func aRenamedVerifiedSourceGetsTheNewTitleTag() throws {
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("doc.opus")
        try Data(try PortableFixtures.document([Word("S1", 0, 500, "hello")], title: "Old")).write(to: source)
        var note = Note(title: "New title")
        note.language = "en_US"
        note.transcript = [TranscriptSegment(text: "hello", start: 0, end: 0.5, speakerID: "S1")]
        let output = directory.appendingPathComponent("out.opus")
        try PortableTranscript.export(note: note, opus: source, destination: output, unassignedLabel: "Unknown speaker")
        let exported = CassiniDocument.read(output)
        #expect(exported.state == .ok)
        #expect(exported.title == "New title")
        #expect(exported.variants.count == 2)
        #expect(exported.selected()?.transcript?.language == "en_US")
        #expect(exported.comments.filter { $0.uppercased().hasPrefix("TITLE=") } == ["TITLE=New title"])
    }

    /// An unverified or stale source is sealed afresh with none of its variants, but its private `x` data travels
    /// verbatim (D53.2 Q3): a fresh seal hashes the audio it covers, so trust is computed again.
    @Test(arguments: [DocumentState.staleAudio, .unverified])
    func exportFromAnUntrustedSourceCarriesItsPrivateData(state: DocumentState) throws {
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let document = try PortableFixtures.documentWithPrivateData([Word("S1", 0, 500, "first")], title: "Note")
        let bytes = state == .staleAudio ? try PortableFixtures.staleTwin(document) : try PortableFixtures.unverifiedTwin(document)
        let source = directory.appendingPathComponent("source.opus")
        try Data(bytes).write(to: source)
        let read = CassiniDocument.read(source)
        try #require(read.state == state)
        var note = Note(title: "Note")
        note.transcript = [TranscriptSegment(text: "dopo", start: 0, end: 0.5, speakerID: "S1")]
        let output = directory.appendingPathComponent("export.opus")

        try PortableTranscript.export(note: note, opus: source, destination: output, unassignedLabel: "Unknown speaker", source: read)

        let exported = CassiniDocument.read(output)
        #expect(exported.state == .ok)
        #expect(exported.manifest?["x"]?.serialized() == read.manifest?["x"]?.serialized())
        #expect(exported.manifest?["x"]?.serialized().contains("9007199254740993") == true)
        #expect(exported.variants.map(\.id) == ["words"])
        #expect(exported.selected()?.transcript?.words.map(\.text) == ["dopo"])
        #expect(exported.comments.contains("X_CUSTOM=keep=me"))
        #expect(try Data(contentsOf: source) == Data(bytes))
    }

    /// Private data that gzip shrinks to almost nothing but that would push the manifest past the payload limit is
    /// refused as too long, not with a codec error, and nothing is written.
    @Test func privateDataTooLargeUncompressedIsTooLong() throws {
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.opus")
        try Data(try PortableFixtures.silence()).write(to: source)
        let notes = JSON.object(JSONObject([("example.com", .string(String(repeating: "a", count: CassiniPayload.maxRaw - 1024)))]))
        let stale = CassiniDocument(state: .staleAudio, manifest: JSONObject([("x", notes)]))
        var note = Note(title: "Note")
        note.transcript = [TranscriptSegment(text: "dopo", start: 0, end: 0.5, speakerID: "S1")]
        let output = directory.appendingPathComponent("export.opus")

        #expect(throws: PortableExportError.tooLong) {
            try PortableTranscript.export(note: note, opus: source, destination: output, unassignedLabel: "Unknown speaker", source: stale)
        }
        #expect(!FileManager.default.fileExists(atPath: output.path))
    }

    @Test func aVerifiedSourceKeepsItsPrivateDataAndVariants() throws {
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("doc.opus")
        try Data(try PortableFixtures.documentWithPrivateData([Word("S1", 0, 500, "hello")], title: "Old")).write(to: source)
        let before = CassiniDocument.read(source)
        try #require(before.state == .ok)
        var note = Note(title: "Old")
        note.transcript = [TranscriptSegment(text: "hello", start: 0, end: 0.5, speakerID: "S1")]
        let output = directory.appendingPathComponent("out.opus")

        try PortableTranscript.export(note: note, opus: source, destination: output, unassignedLabel: "Unknown speaker")

        let exported = CassiniDocument.read(output)
        #expect(exported.state == .ok)
        #expect(exported.manifest?["x"]?.serialized() == before.manifest?["x"]?.serialized())
        #expect(exported.variants.prefix(2).map(\.id) == before.variants.map(\.id))
        #expect(exported.variants.prefix(2).map(\.body) == before.variants.map(\.body))
    }

    /// D56 and D47: every write keeps a speaker's members verbatim, `voiceSource` and members this app does not know
    /// included; only `label` and approved optional colour/naming hints change. iOS diarizes as `spk_N`, so a new
    /// variant adds its own speakers and never
    /// stamps or re-ranks a desktop `<group>~n` voice. The `x["codemyriad.io"]` mirror stays byte for byte.
    @Test func everyWriteKeepsTheSpeakersUnknownMembers() throws {
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let stamp = #"{"inputSHA256":"\#(String(repeating: "a", count: 64))","turnsSHA256":"\#(String(repeating: "b", count: 64))"}"#
        let first = try PortableFixtures.document([Word("others~2", 0, 500, "hello")], title: "Desktop")
        var base = CassiniDocument.read(first)
        base.manifest?["speakers"] = .array([.object(try JSON.parseObject(
            #"{"id":"others~2","label":"Speaker 2","voiceSource":\#(stamp),"futureMember":{"n":9007199254740993}}"#))])
        base.manifest?["x"] = .object(try JSON.parseObject(
            #"{"codemyriad.io":{"meeting":{"speakers":[{"id":"others~2","voiceSource":\#(stamp)}]}}}"#))
        let source = directory.appendingPathComponent("doc.opus")
        try Data(try CassiniDocument.create(first, transcript: Transcript([Word("others~2", 0, 500, "hello")], language: "it"),
                                            title: "Desktop", processing: JSONObject(), existing: base)).write(to: source)
        let before = CassiniDocument.read(source)
        try #require(before.state == .ok)
        let original = try #require(before.manifest?["speakers"]?.array?.first?.object)
        func withLabel(_ label: String, withHints: Bool = false) -> JSONObject {
            var speaker = original
            speaker["label"] = .string(label)
            if withHints {
                speaker["colourIndex"] = .int(0)
                speaker["provenance"] = .string("user")
            }
            return speaker
        }

        // An export with a rename and a variant diarized on this device.
        var note = Note(title: "Desktop")
        note.transcript = [TranscriptSegment(text: "hello", start: 0, end: 0.5, speakerID: "others~2"),
                           TranscriptSegment(text: "hello", start: 0.5, end: 1, speakerID: "spk_1")]
        note.speakers = [NoteSpeaker(id: "others~2", name: "Mira"), NoteSpeaker(id: "spk_1", name: "Speaker 1")]
        let output = directory.appendingPathComponent("out.opus")
        try PortableTranscript.export(note: note, opus: source, destination: output, unassignedLabel: "Unknown speaker")
        let exported = CassiniDocument.read(output)
        #expect(exported.state == .ok)
        let speakers = exported.manifest?["speakers"]?.array?.compactMap { $0.object }
        #expect(speakers == [withLabel("Mira", withHints: true), try JSON.parseObject(#"{"id":"spk_1","label":"Speaker 1","colourIndex":1,"provenance":"unnamed"}"#)])
        #expect(exported.manifest?["x"]?.serialized() == before.manifest?["x"]?.serialized())

        // A rename in place.
        let renamed = directory.appendingPathComponent("renamed.opus")
        try CassiniDocument.relabel(source, existing: before, labels: ["others~2": "Ada"], target: renamed)
        let relabelled = CassiniDocument.read(renamed)
        var renamedSpeaker = withLabel("Ada")
        renamedSpeaker["provenance"] = .string("user")
        #expect(relabelled.manifest?["speakers"]?.array?.compactMap { $0.object } == [renamedSpeaker])
        #expect(relabelled.manifest?["x"]?.serialized() == before.manifest?["x"]?.serialized())
    }

    /// D47 and parity report risk 4: a passage without a speaker is the speaker `unassigned`, labelled as the app shows
    /// such passages in the user's language, never with its raw id, which Android and this app's reader take for an
    /// unlabelled speaker ("Speaker N"). The entry exists only when a word uses it.
    @Test func aPassageWithoutASpeakerIsLabelledAsTheAppShowsIt() throws {
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("audio.opus")
        try Data(try PortableFixtures.silence()).write(to: source)
        var note = Note(title: "Meeting")
        note.speakers = [NoteSpeaker(id: "spk_1", name: "Ada")]
        note.transcript = [TranscriptSegment(text: "hello", start: 0, end: 0.4, speakerID: "spk_1"),
                           TranscriptSegment(text: "chi parla?", start: 0.4, end: 0.9)]
        let output = directory.appendingPathComponent("out.opus")

        try PortableTranscript.export(note: note, opus: source, destination: output, unassignedLabel: "Voce sconosciuta")

        let exported = CassiniDocument.read(output)
        #expect(exported.state == .ok)
        #expect(exported.manifest?["speakers"]?.array?.compactMap { $0.object }
                == [try JSON.parseObject(#"{"id":"spk_1","label":"Ada","colourIndex":0,"provenance":"user"}"#),
                    try JSON.parseObject(#"{"id":"unassigned","label":"Voce sconosciuta"}"#)])
        #expect(exported.selected()?.transcript?.words.map(\.speaker) == ["spk_1", "unassigned", "unassigned"])
        // Every reader, this one included, shows the label as stored.
        let reread = try #require(PortableTranscript.read(from: output))
        var imported = Note(title: "Riunione")
        imported.transcript = reread.segments; imported.speakers = reread.speakers
        #expect(NoteTranscripts.sealed(imported).turns.map(\.name) == [.named("Ada"), .named("Voce sconosciuta")])

        // Without such a passage there is no entry.
        note.transcript[1].speakerID = "spk_1"
        let named = directory.appendingPathComponent("named.opus")
        try PortableTranscript.export(note: note, opus: source, destination: named, unassignedLabel: "Voce sconosciuta")
        #expect(CassiniDocument.read(named).manifest?["speakers"]?.array?.compactMap { $0.object?["id"]?.string } == ["spk_1"])
    }

    /// A verified source that has an `unassigned` entry already keeps it verbatim, its label too: the label was written
    /// when its words were produced (D47), and an export in another language must not rewrite it. The note's name for
    /// `unassigned`, read from that entry, changes the label only once the user renames it, as for any speaker.
    @Test func aVerifiedSourcesUnassignedEntryKeepsItsStoredLabel() throws {
        let directory = try PortableFixtures.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = try PortableFixtures.document([Word("unassigned", 0, 400, "hello")], title: "Shared",
                                                  labels: ["unassigned": "Unknown speaker"])
        var base = CassiniDocument.read(first)
        base.manifest?["speakers"] = .array([.object(try JSON.parseObject(#"{"id":"unassigned","label":"Unknown speaker","futureMember":1}"#))])
        let source = directory.appendingPathComponent("doc.opus")
        try Data(try CassiniDocument.create(first, transcript: Transcript([Word("unassigned", 0, 400, "hello")], language: "en"),
                                            title: "Shared", processing: JSONObject(), existing: base)).write(to: source)
        let portable = try #require(PortableTranscript.read(from: source))
        try #require(portable.state == .ok)
        let entry = try JSON.parseObject(#"{"id":"unassigned","label":"Unknown speaker","futureMember":1}"#)

        // An Italian export that adds a passage without a speaker, and one where the shown version names no one.
        var note = Note(title: "Shared")
        note.transcript = portable.segments + [TranscriptSegment(text: "hello", start: 0.4, end: 0.8)]
        note.speakers = portable.speakers
        var nobody = Note(title: "Shared")
        nobody.transcript = [TranscriptSegment(text: "hello", start: 0, end: 0.8)]
        for (index, exporting) in [note, nobody].enumerated() {
            let output = directory.appendingPathComponent("out-\(index).opus")
            try PortableTranscript.export(note: exporting, opus: source, destination: output, unassignedLabel: "Voce sconosciuta")
            let exported = CassiniDocument.read(output)
            #expect(exported.state == .ok)
            var expected = entry
            if index == 0 {
                expected["colourIndex"] = .int(0)
                expected["provenance"] = .string("source")
            }
            #expect(exported.manifest?["speakers"]?.array?.compactMap { $0.object } == [expected], "export \(index)")
        }

        note.renameSpeaker("unassigned", name: "Mira")
        let renamed = directory.appendingPathComponent("renamed.opus")
        try PortableTranscript.export(note: note, opus: source, destination: renamed, unassignedLabel: "Voce sconosciuta")
        #expect(CassiniDocument.read(renamed).manifest?["speakers"]?.array?.compactMap { $0.object }
                == [try JSON.parseObject(#"{"id":"unassigned","label":"Mira","futureMember":1,"colourIndex":0,"provenance":"user"}"#)])
    }
}

@Suite struct ImportedOnlyTests {
    private func imported(_ text: String) -> TranscriptVersion {
        var version = TranscriptVersion(kind: .imported, segments: [TranscriptSegment(text: text, start: 0, end: 1, speakerID: "S1")],
                                        speakers: [NoteSpeaker(id: "S1", name: "Ada")])
        version.portableID = "words"
        return version
    }

    private func note(showing version: TranscriptVersion, versions: [TranscriptVersion]) -> Note {
        var note = Note(title: "Imported")
        note.versions = versions
        note.selectedVersionID = version.id
        note.transcript = version.segments
        note.speakers = version.speakers
        return note
    }

    @Test func aNoteShowingAnImportedVersionAsReadHoldsOnlyImportedVersions() {
        let first = imported("first"), second = imported("second")
        let note = note(showing: first, versions: [first, second])
        #expect(note.showsImportedVersion)
        #expect(note.holdsOnlyImportedVersions)
    }

    @Test func anEditOrALocalVersionIsSomethingMadeHere() {
        let first = imported("first")
        var edited = note(showing: first, versions: [first])
        edited.transcript[0].text = "edited"
        #expect(!edited.showsImportedVersion)
        #expect(!edited.holdsOnlyImportedVersions)

        let local = TranscriptVersion(kind: .transcription, segments: [TranscriptSegment(text: "nuova", start: 0, end: 1)], speakers: [])
        let withLocal = note(showing: first, versions: [first, local])
        #expect(withLocal.showsImportedVersion)
        #expect(!withLocal.holdsOnlyImportedVersions)

        let empty = TranscriptVersion(kind: .previous, segments: [], speakers: [])
        #expect(note(showing: first, versions: [first, empty]).holdsOnlyImportedVersions)
        #expect(!note(showing: local, versions: [first, local]).showsImportedVersion)
    }
}

@Suite struct ImportedNoteTests {
    private let audio = ImportedAudio(filename: "source.m4a", duration: 12, waveform: [0.5])

    /// A plain import has no words, so no language: never the Settings one (D53.2).
    @Test func aPlainImportIsTitledByItsNameAndWaitsForATranscript() {
        let id = UUID(), date = Date(timeIntervalSince1970: 1_000)
        let note = ImportedNote.make(id: id, displayName: "memo.m4a", fallbackTitle: "Imported audio", sha256: "abc",
                                     importedAt: date, audio: audio)
        #expect(note.id == id)
        #expect(note.title == "memo")
        #expect(note.createdAt == date)
        #expect(note.origin == .imported)
        #expect(note.sourceSha256 == "abc")
        #expect(note.status == .audioOnly)
        #expect(note.language == "")
        #expect(note.document == nil)
        #expect(ImportedNote.wantsTranscription(note))
    }

    @Test func aDocumentBringsItsTitleDateDurationAndTranscript() throws {
        let bytes = try PortableFixtures.document([Word("S1", 0, 500, "hello")], title: "  Council session ")
        let portable = try #require(PortableTranscript(CassiniDocument.read(bytes)))
        let note = ImportedNote.make(id: UUID(), displayName: "export.opus", fallbackTitle: "Imported audio", sha256: "s",
                                     importedAt: Date(timeIntervalSince1970: 0), audio: audio, document: portable)
        #expect(note.title == "Council session")
        #expect(note.createdAt == portable.createdAt)
        #expect(note.duration == 1)
        #expect(note.origin == .importedDocument)
        #expect(note.status == .ready)
        #expect(note.language == "it")
        #expect(note.document?.state == .ok)
        #expect(note.text == "hello")
        #expect(!ImportedNote.wantsTranscription(note))
    }

    @Test func aNewerFormatIsNeverTranscribedOnItsOwn() throws {
        let bytes = try PortableFixtures.document([Word("S1", 0, 500, "hello")], title: "T")
        let newer = try PortableFixtures.rewritingComments(bytes) {
            $0.hasPrefix("CASSINI_FORMAT=") ? "CASSINI_FORMAT=org.cassini.portable-meeting/99" : $0
        }
        let portable = try #require(PortableTranscript(CassiniDocument.read(newer)))
        let note = ImportedNote.make(id: UUID(), displayName: "x.opus", fallbackTitle: "F", sha256: "s", importedAt: Date(),
                                     audio: audio, document: portable)
        #expect(note.document?.state == .unknownFormat)
        #expect(note.title == "x")
        #expect(note.transcript.isEmpty)
        #expect(!ImportedNote.wantsTranscription(note))
    }

    @Test func unplayableAudioIsNotQueued() {
        var note = Note(title: "x")
        note.audio = .unplayable(.unsupportedFormat)
        #expect(!ImportedNote.wantsTranscription(note))
    }
}

@Suite struct DocumentTrustTests {
    @Test func trustFollowsTheDocumentState() {
        #expect(DocumentTrust(.ok) == .verified)
        #expect(DocumentTrust(.unverified) == .notVerified)
        #expect(DocumentTrust(.plainAudio) == .notVerified)
        #expect(DocumentTrust(.staleAudio) == .audioChanged)
        #expect(DocumentTrust(.unreadable) == .unreadable)
        #expect(DocumentTrust(.invalidMetadata) == .unreadable)
        #expect(DocumentTrust(.unknownFormat) == .newerFormat)
        #expect(DocumentTrust.of(Note(title: "plain")) == nil)
    }

    @Test func notVerifiedStopsShowingItsBannerAfterPlayAnyway() {
        #expect(!DocumentTrust.showsBanner(DocumentInfo(state: .ok)))
        #expect(DocumentTrust.showsBanner(DocumentInfo(state: .unverified)))
        #expect(!DocumentTrust.showsBanner(DocumentInfo(state: .unverified, trustAcknowledged: true)))
        #expect(DocumentTrust.showsBanner(DocumentInfo(state: .staleAudio, trustAcknowledged: true)))
        for state in [DocumentState.staleAudio, .unreadable, .invalidMetadata, .unknownFormat] {
            #expect(DocumentTrust.showsBanner(DocumentInfo(state: state)))
        }
        #expect(DocumentTrust.allCases.filter(\.offersPlayAnyway) == [.notVerified])
    }

    // ports: NoteViewModelTest#theTrustChipTogglesTheBannerAndPlayAnywayAcknowledges
    @Test func theTrustChipTogglesTheBannerAndPlayAnywayAcknowledges() {
        // The chip shows a verified note's banner and hides it again.
        let verified = DocumentInfo(state: .ok)
        #expect(!DocumentTrust.showsBanner(verified, toggled: false))
        #expect(DocumentTrust.showsBanner(verified, toggled: true))
        // Not verified shows the banner, with Play anyway, which acknowledges it; the chip brings it back.
        var unverified = DocumentInfo(state: .unverified)
        #expect(DocumentTrust.showsBanner(unverified))
        #expect(DocumentTrust(unverified.state).offersPlayAnyway)
        unverified.trustAcknowledged = true
        #expect(!DocumentTrust.showsBanner(unverified))
        #expect(DocumentTrust.showsBanner(unverified, toggled: true))
        // The chip hides a banner shown by default.
        #expect(!DocumentTrust.showsBanner(DocumentInfo(state: .staleAudio), toggled: true))
    }
}
