import CassiniCore
import Foundation

/// How the note's transcript was made on this device, for the `provenance.speechToText` record of an export. The keys of
/// `record()` are Android's (`JobProvenance`, `SpeakerAttribution.record`) and a contract with the desktop pipeline:
/// never rename them.
public struct TranscriptProvenance: Codable, Hashable, Sendable {
    public static let appleSpeech = "apple-speechtranscriber"
    /// The processing step's `backend`: Apple's speech framework, which runs the model on the device.
    public static let appleSpeechBackend = "Apple Speech framework (SpeechAnalyzer, on-device)"
    /// The processing step's `source`, as Android writes it for every transcription.
    public static let recordingSource = "recording"
    /// How the recording reaches the recognizer (`x-segmentation`): `SpeechWindows` and `AppleSpeechTranscriber`.
    public static let appleSegmentation =
        "whole file streamed to SpeechAnalyzer in 1 s blocks, the analyzer finds its own segments; "
        + "a resume restarts 1 s before the checkpoint and drops the words that end at or before it"

    /// The speaker step's record (`x-speakerDiarization`), with `x-incrementalDiarization` beside it.
    public struct SpeakerDiarization: Codable, Hashable, Sendable {
        /// How the words get their speakers (`Diarization.assign`, `SpeakerAttribution.assign`): Android's rule, word
        /// for word.
        public static let assignmentRule = "largest union overlap; nearest turn in gaps; one speaker per word"
        /// Android's `SpeakerAttribution.record` values for Sortformer.
        public static let sortformerBackend = "sherpa-onnx 1.13.7 with Sortformer diarization, CPU, 2 threads"
        public static let sortformerModel = "nvidia/Nemotron-3-Diarization INT8"
        /// Android's `x-incrementalDiarization`: how the streaming diarizer reads the recording.
        public static let incrementalWindows = "28 s windows with 2 s overlap, persistent Sortformer speaker cache"

        public var backend: String
        public var model: String
        /// The revision the model was made from.
        public var modelRevision: String
        /// The SHA-256 of the model file.
        public var modelSha256: String
        /// Sortformer's activity threshold and minimum turn and gap (`Diarization`).
        public var threshold: Double
        public var minDurationOn: Double
        public var minDurationOff: Double
        /// Time spent in the analysis itself, without the model install.
        public var elapsedMs: Int64
        public var turnCount: Int
        public var speakerCount: Int
        public var assignment: String
        /// Whether the speakers were separated from a mix before the analysis; iOS never does.
        public var sourceSeparation: Bool
        /// `x-incrementalDiarization` of the record: how a streaming diarizer read the recording.
        public var incremental: String?

        public init(backend: String = sortformerBackend, model: String = sortformerModel, modelRevision: String,
                    modelSha256: String, threshold: Double = decimal(Diarization.threshold),
                    minDurationOn: Double = decimal(Diarization.minDurationOn),
                    minDurationOff: Double = decimal(Diarization.minDurationOff), elapsedMs: Int64, turnCount: Int,
                    speakerCount: Int, assignment: String = assignmentRule, sourceSeparation: Bool = false,
                    incremental: String? = nil) {
            self.backend = backend; self.model = model; self.modelRevision = modelRevision
            self.modelSha256 = modelSha256; self.threshold = threshold; self.minDurationOn = minDurationOn
            self.minDurationOff = minDurationOff; self.elapsedMs = elapsedMs; self.turnCount = turnCount
            self.speakerCount = speakerCount; self.assignment = assignment; self.sourceSeparation = sourceSeparation
            self.incremental = incremental
        }

        /// The record of a Sortformer analysis, with Android's values (`SpeakerAttribution.record`): `revision` and
        /// `sha256` are the pinned model's (`ModelCatalog.diarization*`), `turnCount` the turns and `speakerCount`
        /// the speakers of the words. `streaming` adds `x-incrementalDiarization`.
        public static func sortformer(revision: String, sha256: String, elapsedMs: Int64, turnCount: Int,
                                      speakerCount: Int, streaming: Bool) -> SpeakerDiarization {
            SpeakerDiarization(modelRevision: revision, modelSha256: sha256, elapsedMs: elapsedMs, turnCount: turnCount,
                               speakerCount: speakerCount, incremental: streaming ? incrementalWindows : nil)
        }

        /// A Float written as its shortest decimal (0.3, not the Float's 0.30000001192…), as Android's `toDouble()`
        /// of these constants serialises.
        public static func decimal(_ value: Float) -> Double { Double("\(value)") ?? Double(value) }

        func record() -> JSONObject {
            JSONObject([("backend", .string(backend)), ("model", .string(model)), ("modelRevision", .string(modelRevision)),
                        ("modelSha256", .string(modelSha256)), ("threshold", .number("\(threshold)")),
                        ("minDurationOn", .number("\(minDurationOn)")), ("minDurationOff", .number("\(minDurationOff)")),
                        ("elapsedMs", .int(elapsedMs)), ("turnCount", .int(turnCount)),
                        ("speakerCount", .int(speakerCount)), ("assignment", .string(assignment)),
                        ("sourceSeparation", .bool(sourceSeparation))])
        }
    }

    /// `x-speakerIdentification`: counts only, so which person a voice resembles never enters the document.
    public struct SpeakerIdentification: Codable, Hashable, Sendable {
        public static let cosine = "cosine"

        /// The print model's name.
        public var model: String
        /// The SHA-256 of the print model's file.
        public var sha256: String
        /// The length of a print.
        public var dim: Int
        public var metric: String
        public var autoThreshold: Double
        public var suggestThreshold: Double
        public var margin: Double
        /// Speakers the analysis made a print for.
        public var speakersWithPrints: Int
        /// Speakers named automatically from a saved voice.
        public var autoApplied: Int
        /// Speakers offered a saved voice without being named by it.
        public var suggested: Int

        public init(model: String, sha256: String, dim: Int, metric: String = cosine, autoThreshold: Double,
                    suggestThreshold: Double, margin: Double, speakersWithPrints: Int, autoApplied: Int, suggested: Int) {
            self.model = model; self.sha256 = sha256; self.dim = dim; self.metric = metric
            self.autoThreshold = autoThreshold; self.suggestThreshold = suggestThreshold; self.margin = margin
            self.speakersWithPrints = speakersWithPrints; self.autoApplied = autoApplied; self.suggested = suggested
        }

        /// The record of CAM++ prints (`VoiceprintModel`), as Android's `JobProvenance.identification` writes it:
        /// the model's name and SHA-256, the print length `dim` and Android's thresholds, as their shortest decimals.
        public static func campplus(dim: Int, speakersWithPrints: Int, autoApplied: Int, suggested: Int) -> SpeakerIdentification {
            let thresholds = VoiceprintModel.thresholds
            let decimal = SpeakerDiarization.decimal
            return SpeakerIdentification(model: VoiceprintModel.name, sha256: VoiceprintModel.sha256, dim: dim,
                                         autoThreshold: decimal(thresholds.automatic),
                                         suggestThreshold: decimal(thresholds.suggest), margin: decimal(thresholds.margin),
                                         speakersWithPrints: speakersWithPrints, autoApplied: autoApplied,
                                         suggested: suggested)
        }

        func record() -> JSONObject {
            var record = JSONObject([("model", .string(model)), ("sha256", .string(sha256))])
            record["dim"] = .int(dim)
            record["metric"] = .string(metric)
            record["autoThreshold"] = .number("\(autoThreshold)")
            record["suggestThreshold"] = .number("\(suggestThreshold)")
            record["margin"] = .number("\(margin)")
            record["speakersWithPrints"] = .int(speakersWithPrints)
            record["autoApplied"] = .int(autoApplied)
            record["suggested"] = .int(suggested)
            return record
        }
    }

    // The spec's processing step.
    public var backend: String?
    public var engine: String
    public var model: String?
    public var device: String?
    public var source: String?
    public var version: String?
    /// The run's language (`TranscriptLanguage.ofRun`): BCP-47, `und` when the recognizer does not say.
    public var language: String
    /// Time spent in the speech analyzer, over every run of the job.
    public var inferenceMs: Int64
    /// How the recording was cut for the recognizer (`x-segmentation`).
    public var segmentation: String?
    /// Where the last run resumed from a checkpoint; 0 for an uninterrupted job.
    public var resumedFromMs: Int64
    /// Set when the speakers were told apart.
    public var speakerDiarization: SpeakerDiarization?
    /// Set when the speakers' prints were matched against the saved voices.
    public var speakerIdentification: SpeakerIdentification?

    public init(backend: String? = nil, engine: String = appleSpeech, model: String? = nil, device: String? = nil,
                source: String? = nil, version: String? = nil, language: String, inferenceMs: Int64,
                segmentation: String? = nil, resumedFromMs: Int64, speakerDiarization: SpeakerDiarization? = nil,
                speakerIdentification: SpeakerIdentification? = nil) {
        self.backend = backend; self.engine = engine; self.model = model; self.device = device; self.source = source
        self.version = version; self.language = language; self.inferenceMs = inferenceMs
        self.segmentation = segmentation; self.resumedFromMs = resumedFromMs
        self.speakerDiarization = speakerDiarization; self.speakerIdentification = speakerIdentification
    }

    /// The record of a run of Apple's recognizer on `device`: the processing step with iOS's values, then the run's
    /// own members. `language` is the run's (`TranscriptLanguage.ofRun`), the locale that ran rather than the one asked
    /// for; `model` is what the transcriber names its model (nil leaves the key out); `system` the OS and its build,
    /// which carries the speech framework.
    public static func appleRun(language: String, inferenceMs: Int64, resumedFromMs: Int64, model: String?,
                                   device: RunDevice) -> TranscriptProvenance {
        TranscriptProvenance(backend: appleSpeechBackend, model: model, device: device.description,
                             source: recordingSource, version: "Speech framework of \(device.system)",
                             language: language, inferenceMs: inferenceMs, segmentation: appleSegmentation,
                             resumedFromMs: resumedFromMs)
    }

    /// The processing step's `backend` and `engine` of a Parakeet run, as Android writes them.
    public static let sherpaBackend = "sherpa-onnx"
    public static let parakeetEngine = "Parakeet TDT"
    /// The sherpa-onnx release the native runtime is built from (scripts/native-dependencies.json).
    public static let sherpaVersion = "1.13.7"

    /// The record of a Parakeet run, with Android's values (`JobProvenance.recognition`) but `device`: `model` is
    /// `<id> <precision>`, `revision` the model's pinned revision, `segmentation` how the audio was cut. The language
    /// is `und`: Parakeet does not say which one it heard (D53.2).
    public static func parakeetRun(model: String, revision: String, segmentation: String, inferenceMs: Int64,
                                   resumedFromMs: Int64, device: RunDevice) -> TranscriptProvenance {
        TranscriptProvenance(backend: sherpaBackend, engine: parakeetEngine, model: model, device: device.description,
                             source: recordingSource, version: "sherpa-onnx \(sherpaVersion); model revision \(revision)",
                             language: TranscriptLanguage.ofRun(reported: nil), inferenceMs: inferenceMs,
                             segmentation: segmentation,
                             resumedFromMs: resumedFromMs)
    }

    /// The record as an export writes it.
    public func record() -> JSONObject {
        var record = JSONObject()
        if let backend { record["backend"] = .string(backend) }
        record["engine"] = .string(engine)
        if let model { record["model"] = .string(model) }
        if let device { record["device"] = .string(device) }
        if let source { record["source"] = .string(source) }
        if let version { record["version"] = .string(version) }
        record["language"] = .string(language)
        record["x-inferenceMs"] = .int(inferenceMs)
        if let segmentation { record["x-segmentation"] = .string(segmentation) }
        record["x-resumedFromMs"] = .int(resumedFromMs)
        if let speakerDiarization {
            record["x-speakerDiarization"] = .object(speakerDiarization.record())
            if let incremental = speakerDiarization.incremental { record["x-incrementalDiarization"] = .string(incremental) }
        }
        if let speakerIdentification { record["x-speakerIdentification"] = .object(speakerIdentification.record()) }
        return record
    }
}

/// The device a run happened on, for the processing step's `device` and `version`.
public struct RunDevice: Hashable, Sendable, CustomStringConvertible {
    /// The hardware model identifier, such as "iPhone17,1".
    public var model: String
    /// The OS, its version and build, such as "iOS 26.0.1 (23A355)".
    public var system: String
    public init(model: String, system: String) { self.model = model; self.system = system }

    /// "iPhone17,1, iOS 26.0.1 (23A355)".
    public var description: String { "\(model), \(system)" }
}
