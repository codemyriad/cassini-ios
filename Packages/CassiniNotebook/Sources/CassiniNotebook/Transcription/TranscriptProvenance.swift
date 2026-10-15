import CassiniCore
import Foundation

/// How the note's transcript was made on this device, for the `provenance.speechToText` record of an export. The keys of
/// `record()` are Android's (`JobProvenance`, `SpeakerAttribution.record`) and a contract with the desktop pipeline:
/// never rename them. Every member added after the first release is optional, so a `provenance.json` an older build
/// wrote still reads, and its record leaves out what that build did not know.
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

    /// The speaker step's record (`x-speakerDiarization`).
    public struct SpeakerDiarization: Codable, Hashable, Sendable {
        public static let fluidAudio = "fluidaudio"
        /// How the words get their speakers (`SpeakerAttribution.assign`): Android's rule, word for word.
        public static let assignmentRule = "largest union overlap; nearest turn in gaps; one speaker per word"

        public var backend: String
        public var model: String
        /// The Hugging Face revision the models were installed from, when the analysis tells it.
        public var modelRevision: String?
        /// The model fingerprint the voiceprints also carry (`modelSha256`; older builds stored it as `sha`).
        public var modelSha256: String?
        /// Time spent in the analysis itself, without the model install; nil in records of older builds.
        public var elapsedMs: Int64?
        public var turnCount: Int
        public var speakerCount: Int
        /// Nil in records of older builds, which did not write it.
        public var assignment: String?
        /// Whether the speakers were separated from a mix before the analysis; iOS never does. Nil in older records.
        public var sourceSeparation: Bool?

        public init(backend: String = fluidAudio, model: String, modelRevision: String? = nil, modelSha256: String?,
                    elapsedMs: Int64? = nil, turnCount: Int, speakerCount: Int, assignment: String? = assignmentRule,
                    sourceSeparation: Bool? = false) {
            self.backend = backend; self.model = model; self.modelRevision = modelRevision
            self.modelSha256 = modelSha256; self.elapsedMs = elapsedMs; self.turnCount = turnCount
            self.speakerCount = speakerCount; self.assignment = assignment; self.sourceSeparation = sourceSeparation
        }

        /// From a `SpeakerAnalyzing.modelIdentity` of the form `model:sha256`.
        public init(identity: String, backend: String = fluidAudio, modelRevision: String? = nil, elapsedMs: Int64? = nil,
                    turnCount: Int, speakerCount: Int) {
            let (model, sha) = TranscriptProvenance.split(identity)
            self.init(backend: backend, model: model, modelRevision: modelRevision, modelSha256: sha,
                      elapsedMs: elapsedMs, turnCount: turnCount, speakerCount: speakerCount)
        }

        private enum CodingKeys: String, CodingKey {
            case backend, model, modelRevision, modelSha256, elapsedMs, turnCount, speakerCount, assignment
            case sourceSeparation
            /// What builds before the rename stored `modelSha256` as.
            case sha
        }

        public init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            backend = try c.decode(String.self, forKey: .backend)
            model = try c.decode(String.self, forKey: .model)
            modelRevision = try c.decodeIfPresent(String.self, forKey: .modelRevision)
            modelSha256 = try c.decodeIfPresent(String.self, forKey: .modelSha256)
                ?? c.decodeIfPresent(String.self, forKey: .sha)
            elapsedMs = try c.decodeIfPresent(Int64.self, forKey: .elapsedMs)
            turnCount = try c.decode(Int.self, forKey: .turnCount)
            speakerCount = try c.decode(Int.self, forKey: .speakerCount)
            assignment = try c.decodeIfPresent(String.self, forKey: .assignment)
            sourceSeparation = try c.decodeIfPresent(Bool.self, forKey: .sourceSeparation)
        }

        public func encode(to encoder: any Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(backend, forKey: .backend)
            try c.encode(model, forKey: .model)
            try c.encodeIfPresent(modelRevision, forKey: .modelRevision)
            try c.encodeIfPresent(modelSha256, forKey: .modelSha256)
            try c.encodeIfPresent(elapsedMs, forKey: .elapsedMs)
            try c.encode(turnCount, forKey: .turnCount)
            try c.encode(speakerCount, forKey: .speakerCount)
            try c.encodeIfPresent(assignment, forKey: .assignment)
            try c.encodeIfPresent(sourceSeparation, forKey: .sourceSeparation)
        }

        func record() -> JSONObject {
            var record = JSONObject([("backend", .string(backend)), ("model", .string(model))])
            if let modelRevision { record["modelRevision"] = .string(modelRevision) }
            if let modelSha256 { record["modelSha256"] = .string(modelSha256) }
            if let elapsedMs { record["elapsedMs"] = .int(elapsedMs) }
            record["turnCount"] = .int(turnCount)
            record["speakerCount"] = .int(speakerCount)
            if let assignment { record["assignment"] = .string(assignment) }
            if let sourceSeparation { record["sourceSeparation"] = .bool(sourceSeparation) }
            return record
        }
    }

    /// `x-speakerIdentification`: counts only, so which person a voice resembles never enters the document.
    public struct SpeakerIdentification: Codable, Hashable, Sendable {
        public static let cosine = "cosine"

        /// The print model, without its fingerprint.
        public var model: String
        /// The fingerprint the prints carry with the model.
        public var sha256: String?
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

        public init(model: String, sha256: String?, dim: Int, metric: String = cosine, autoThreshold: Double,
                    suggestThreshold: Double, margin: Double, speakersWithPrints: Int, autoApplied: Int, suggested: Int) {
            self.model = model; self.sha256 = sha256; self.dim = dim; self.metric = metric
            self.autoThreshold = autoThreshold; self.suggestThreshold = suggestThreshold; self.margin = margin
            self.speakersWithPrints = speakersWithPrints; self.autoApplied = autoApplied; self.suggested = suggested
        }

        /// The record of prints of the model `identity` (`model:sha256`), `dim` long, matched with `thresholds`. The
        /// thresholds are written as their shortest decimal (0.85, not the Float's 0.8500000238…).
        public init(identity: String, dim: Int, thresholds: VoiceThresholds, speakersWithPrints: Int, autoApplied: Int,
                    suggested: Int) {
            let (model, sha) = TranscriptProvenance.split(identity)
            self.init(model: model, sha256: sha, dim: dim, autoThreshold: Self.decimal(thresholds.automatic),
                      suggestThreshold: Self.decimal(thresholds.suggest), margin: Self.decimal(thresholds.margin),
                      speakersWithPrints: speakersWithPrints, autoApplied: autoApplied, suggested: suggested)
        }

        private static func decimal(_ value: Float) -> Double { Double("\(value)") ?? Double(value) }

        func record() -> JSONObject {
            var record = JSONObject([("model", .string(model))])
            if let sha256 { record["sha256"] = .string(sha256) }
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

    // The spec's processing step. Nil in records of builds that did not write them.
    public var backend: String?
    public var engine: String
    public var model: String?
    public var device: String?
    public var source: String?
    public var version: String?
    /// BCP-47.
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
    /// own members. `model` is what the transcriber names its model (nil leaves the key out); `system` the OS and its
    /// build, which carries the speech framework.
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
    /// is empty: Parakeet does not say which one it heard.
    public static func parakeetRun(model: String, revision: String, segmentation: String, inferenceMs: Int64,
                                   resumedFromMs: Int64, device: RunDevice) -> TranscriptProvenance {
        TranscriptProvenance(backend: sherpaBackend, engine: parakeetEngine, model: model, device: device.description,
                             source: recordingSource, version: "sherpa-onnx \(sherpaVersion); model revision \(revision)",
                             language: "", inferenceMs: inferenceMs, segmentation: segmentation,
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
        if let speakerDiarization { record["x-speakerDiarization"] = .object(speakerDiarization.record()) }
        if let speakerIdentification { record["x-speakerIdentification"] = .object(speakerIdentification.record()) }
        return record
    }

    /// `model:sha256` as its two parts; the second is nil without a colon.
    static func split(_ identity: String) -> (model: String, sha: String?) {
        let parts = identity.split(separator: ":", maxSplits: 1).map(String.init)
        return (parts.first ?? identity, parts.count > 1 ? parts[1] : nil)
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
