import Foundation
import Testing
import CassiniCore
import CassiniNotebook

/// The `provenance.speechToText` record pinned against Android's: the same keys with the same JSON types, less the
/// members docs/differences.md lists as not applicable to iOS. Android's key sets are copied from
/// `JobProvenance` / `SpeakerAttribution.record` and the golden `Golden010.provenance` its
/// `TranscriptionJobTest#provenanceEqualsThe010Record` compares with.
@Suite struct ProvenanceGoldenTests {
    enum Kind: Hashable { case string, int, double, bool, object }

    /// Android's transcription record with speakers (`Golden010.provenance`), without a merge.
    static let android: [String: Kind] = [
        "backend": .string, "engine": .string, "model": .string, "device": .string, "source": .string,
        "version": .string, "language": .string, "x-inferenceMs": .int, "x-segmentation": .string,
        "x-resumedFromMs": .int, "x-speakerDiarization": .object, "x-incrementalDiarization": .string,
        "x-speakerIdentification": .object,
    ]
    /// Android's `x-speakerDiarization` (`SpeakerAttribution.record`).
    static let androidDiarization: [String: Kind] = [
        "backend": .string, "model": .string, "modelRevision": .string, "modelSha256": .string, "threshold": .double,
        "minDurationOn": .double, "minDurationOff": .double, "elapsedMs": .int, "turnCount": .int,
        "speakerCount": .int, "assignment": .string, "sourceSeparation": .bool,
    ]
    /// Android's `x-speakerIdentification` (`JobProvenance.identification`).
    static let androidIdentification: [String: Kind] = [
        "model": .string, "sha256": .string, "dim": .int, "metric": .string, "autoThreshold": .double,
        "suggestThreshold": .double, "margin": .double, "speakersWithPrints": .int, "autoApplied": .int,
        "suggested": .int,
    ]
    static let device = RunDevice(model: "iPhone17,1", system: "iOS 26.0.1 (23A355)")
    static let diarizationRevision = "f667ed73aee57d40cc39428eb768b4fd87a0a29e"
    static let diarizationSha = "01d1f893f394cc0418ae78425d216ed62c334c0125e650135332a7a8e595f168"

    /// A run as the job records it: the words, then the speaker step with its matches (Sortformer and CAM++, as
    /// Android's).
    static func run() -> TranscriptProvenance {
        var run = TranscriptProvenance.appleRun(language: "it-IT", inferenceMs: 4_000, resumedFromMs: 52_000,
                                                model: "Apple SpeechTranscriber it-IT", device: device)
        run.speakerDiarization = .sortformer(revision: diarizationRevision, sha256: diarizationSha, elapsedMs: 750,
                                             turnCount: 3, speakerCount: 2, streaming: true)
        run.speakerIdentification = .campplus(dim: 512, speakersWithPrints: 2, autoApplied: 1, suggested: 1)
        return run
    }

    static func kinds(_ object: JSONObject) -> [String: Kind] {
        Dictionary(uniqueKeysWithValues: object.pairs.map { pair in
            let kind: Kind = switch pair.value {
            case .string: .string
            case .bool: .bool
            case .object: .object
            case .number(let lexeme): lexeme.contains(where: { ".eE".contains($0) }) ? .double : .int
            case .null, .array: .object
            }
            return (pair.key, kind)
        })
    }

    // ports: TranscriptionJobTest#provenanceEqualsThe010Record (the key sets and types; iOS's values are its own)
    @Test func theRecordHasAndroidsKeysAndTypes() throws {
        let record = Self.run().record()
        #expect(Self.kinds(record) == Self.android)
        let diarization = try #require(record["x-speakerDiarization"]?.object)
        #expect(Self.kinds(diarization) == Self.androidDiarization)
        let identification = try #require(record["x-speakerIdentification"]?.object)
        #expect(Self.kinds(identification) == Self.androidIdentification)
    }

    @Test func theRecordHoldsIOSValues() throws {
        let record = Self.run().record()
        #expect(record["backend"] == .string("Apple Speech framework (SpeechAnalyzer, on-device)"))
        #expect(record["engine"] == .string("apple-speechtranscriber"))
        #expect(record["model"] == .string("Apple SpeechTranscriber it-IT"))
        #expect(record["device"] == .string("iPhone17,1, iOS 26.0.1 (23A355)"))
        #expect(record["source"] == .string("recording"))
        #expect(record["version"] == .string("Speech framework of iOS 26.0.1 (23A355)"))
        #expect(record["x-segmentation"] == .string(TranscriptProvenance.appleSegmentation))
        #expect(record["x-resumedFromMs"] == .int(52_000))
        #expect(record["x-incrementalDiarization"]
            == .string("28 s windows with 2 s overlap, persistent Sortformer speaker cache"))
        let diarization = try #require(record["x-speakerDiarization"]?.object)
        // Android's `SpeakerAttribution.record`, value for value.
        #expect(diarization["backend"] == .string("sherpa-onnx 1.13.7 with Sortformer diarization, CPU, 2 threads"))
        #expect(diarization["model"] == .string("nvidia/Nemotron-3-Diarization INT8"))
        #expect(diarization["modelSha256"] == .string(Self.diarizationSha))
        #expect(diarization["modelRevision"] == .string(Self.diarizationRevision))
        #expect(diarization["threshold"] == .number("0.5"))
        #expect(diarization["minDurationOn"] == .number("0.3"), "the shortest decimal, not the Float's")
        #expect(diarization["minDurationOff"] == .number("0.5"))
        #expect(diarization["elapsedMs"] == .int(750))
        #expect(diarization["assignment"] == .string("largest union overlap; nearest turn in gaps; one speaker per word"),
                "Android's rule, which Diarization.assign follows")
        #expect(diarization["sourceSeparation"] == .bool(false))
        // Android's `JobProvenance.identification`.
        let identification = try #require(record["x-speakerIdentification"]?.object)
        #expect(identification["model"] == .string("3dspeaker_speech_campplus_sv_en_voxceleb_16k"))
        #expect(identification["sha256"] == .string("357a834f702b80161e5b981182c038e18553c1f2ca752ed6cec2052365d4129b"))
        #expect(identification["metric"] == .string("cosine"))
        #expect(identification["autoThreshold"] == .number("0.72"), "the shortest decimal, not the Float's")
        #expect(identification["suggestThreshold"] == .number("0.5"))
        #expect(identification["margin"] == .number("0.08"))
        #expect(identification["dim"] == .int(512))
    }

    /// A whole-file analysis that did not stream has no `x-incrementalDiarization`, as Android's re-attribution.
    @Test func onlyAStreamedAnalysisNamesItsWindows() {
        var run = Self.run()
        run.speakerDiarization = .sortformer(revision: Self.diarizationRevision, sha256: Self.diarizationSha,
                                             elapsedMs: 1, turnCount: 1, speakerCount: 1, streaming: false)
        #expect(run.record()["x-incrementalDiarization"] == nil)
    }

    /// `provenance.json` as builds before these members wrote it: it still reads, its old `sha` is the model's
    /// SHA-256, and the export leaves out what that build did not record.
    @Test func aRecordOfAnOlderBuildStillReadsAndExports() throws {
        let legacy = """
        {"provenance":{"engine":"apple-speechtranscriber","inferenceMs":1200,"language":"en-US","resumedFromMs":0},
         "speakerDiarization":{"backend":"fluidaudio","model":"m","sha":"abc","speakerCount":2,"turnCount":3},
         "speakerIDs":["x_a","x_b"],"words":"\(ProvenanceRecord.fingerprint(of: []))"}
        """
        let decoded = try JSONDecoder().decode(ProvenanceRecord.self, from: Data(legacy.utf8))
        let diarization = try #require(decoded.speakerDiarization)
        #expect(diarization.modelSha256 == "abc")
        #expect(diarization.assignment == nil && diarization.elapsedMs == nil && diarization.sourceSeparation == nil)
        #expect(decoded.speakerIdentification == nil)
        var run = decoded.provenance
        run.speakerDiarization = diarization
        let record = run.record()
        #expect(record.keys == ["engine", "language", "x-inferenceMs", "x-resumedFromMs", "x-speakerDiarization"])
        #expect(record["x-speakerDiarization"]?.object?.keys == ["backend", "model", "modelSha256", "turnCount", "speakerCount"])

        // Written again, the record keeps the new name only.
        var again = decoded
        again.speakerIdentification = Self.run().speakerIdentification
        let text = try #require(String(data: JSONEncoder().encode(again), encoding: .utf8))
        #expect(text.contains("\"modelSha256\":\"abc\"") && !text.contains("\"sha\""))
        #expect(try JSONDecoder().decode(ProvenanceRecord.self, from: Data(text.utf8)) == again)
    }

    @Test func aFullRecordSurvivesProvenanceJSON() throws {
        let words = [TranscriptSegment(text: "Ciao", start: 0, end: 1, speakerID: "x_a",
                                       words: [TimedWord(text: "Ciao", start: 0, end: 1)])]
        let run = Self.run()
        var record = ProvenanceRecord(provenance: run, transcript: words)
        #expect(record.provenance.speakerIdentification == nil, "the speaker records come from the speaker step")
        record.addSpeakers(try #require(run.speakerDiarization), identification: run.speakerIdentification,
                           transcript: words)
        let decoded = try JSONDecoder().decode(ProvenanceRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded.provenance(for: words) == run)
        var other = words
        other[0].speakerID = "y_a"
        #expect(decoded.provenance(for: other)?.speakerIdentification == nil, "held with the speaker record")
    }

    static let step = ["backend", "engine", "model", "device", "language", "source", "version"]

    /// The spec's processing step: its seven members are strings, and none holds a URL or a hostname.
    @Test func theProcessingStepIsWhatTheSpecAllows() throws {
        let record = Self.run().record()
        for key in Self.step {
            let value = try #require(record[key]?.string, "\(key) is a string")
            #expect(!value.contains("://") && !value.contains("www.") && !value.contains(".com"), "\(key): \(value)")
        }
    }

    /// The same against cassini-format's schema, from the checkout beside this repository.
    @Test(.enabled(if: Conformance.available, Comment(rawValue: Conformance.missing)))
    func theProcessingStepMatchesThePublishedSchema() throws {
        let record = Self.run().record()
        let schema = Conformance.directory.deletingLastPathComponent()
            .appendingPathComponent("cassini-portable-meeting-manifest-v1.schema.json")
        let text = try String(contentsOf: schema, encoding: .utf8)
        let step = Self.step
        let properties = try JSON.parseObject(text).object("$defs").object("processingStep").object("properties")
        #expect(Set(properties.keys) == Set(step), "the spec's processing step is the one this test knows")
        for key in properties.keys {
            #expect(try properties.object(key).string("type") == "string")
            #expect(record[key]?.string != nil, "\(key) is written as a string")
        }
    }

    // ports: SpeakerAttributionTest#newVariantPreservesAudioEarlierWordsAndNamedSpeakers (x-sourceAttribution)
    @Test func aReattributionNamesItsSourceAndItsAudit() throws {
        let audit = JSONObject([("ran", .bool(true)), ("mode", .string("annotate")), ("wordsMeasured", .int(2)),
                                ("wordsFlagged", .int(1)), ("wordsDropped", .int(0)), ("x-producer", .string("desktop"))])
        let record = ExportProvenance.record(run: Self.run(), merges: nil, derivedFrom: nil, attributedFrom: "words",
                                             sourceAttribution: audit)
        #expect(record["x-derivedFromTranscript"] == .string("words"))
        #expect(record["x-sourceAttribution"] == .object(audit))
        #expect(record["x-speakerDiarization"] != nil)

        // A merge of it names the merge's source instead, as Android's merged variant does.
        let merged = ExportProvenance.record(run: Self.run(), merges: ["b": "a"], derivedFrom: "attributed",
                                             attributedFrom: "words", sourceAttribution: audit)
        #expect(merged["x-derivedFromTranscript"] == .string("attributed"))
        #expect(merged["x-sourceAttribution"] == .object(audit))

        // Without the analysis's speakers the record is not the re-attribution's.
        var words = Self.run()
        words.speakerDiarization = nil
        let plain = ExportProvenance.record(run: words, merges: nil, derivedFrom: nil, attributedFrom: "words",
                                            sourceAttribution: audit)
        #expect(plain["x-derivedFromTranscript"] == nil && plain["x-sourceAttribution"] == nil)
        // A first analysis, made in place, has no source.
        let first = ExportProvenance.record(run: Self.run(), merges: nil, derivedFrom: nil)
        #expect(first["x-derivedFromTranscript"] == nil && first["x-sourceAttribution"] == nil)
    }
}
