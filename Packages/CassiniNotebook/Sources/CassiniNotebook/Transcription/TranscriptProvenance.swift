import CassiniCore
import Foundation

/// How the note's transcript was made on this device, for the `provenance.speechToText` record of an export. The keys of
/// `record()` are a contract with the desktop pipeline: never rename them.
public struct TranscriptProvenance: Codable, Hashable, Sendable {
    public static let appleSpeech = "apple-speechtranscriber"

    public struct SpeakerDiarization: Codable, Hashable, Sendable {
        public static let fluidAudio = "fluidaudio"
        public var backend: String
        public var model: String
        /// The weights' SHA-256, when the model identity carries it.
        public var sha: String?
        public var turnCount: Int
        public var speakerCount: Int

        public init(backend: String = fluidAudio, model: String, sha: String?, turnCount: Int, speakerCount: Int) {
            self.backend = backend; self.model = model; self.sha = sha; self.turnCount = turnCount
            self.speakerCount = speakerCount
        }

        /// From a `SpeakerAnalyzing.modelIdentity` of the form `model:sha256`.
        public init(identity: String, turnCount: Int, speakerCount: Int) {
            let parts = identity.split(separator: ":", maxSplits: 1).map(String.init)
            self.init(model: parts.first ?? identity, sha: parts.count > 1 ? parts[1] : nil, turnCount: turnCount,
                      speakerCount: speakerCount)
        }
    }

    public var engine: String
    /// BCP-47.
    public var language: String
    /// Time spent in the speech analyzer, over every run of the job.
    public var inferenceMs: Int64
    /// Where the last run resumed from a checkpoint; 0 for an uninterrupted job.
    public var resumedFromMs: Int64
    /// Set when the speakers were told apart.
    public var speakerDiarization: SpeakerDiarization?

    public init(engine: String = appleSpeech, language: String, inferenceMs: Int64, resumedFromMs: Int64,
                speakerDiarization: SpeakerDiarization? = nil) {
        self.engine = engine; self.language = language; self.inferenceMs = inferenceMs
        self.resumedFromMs = resumedFromMs; self.speakerDiarization = speakerDiarization
    }

    /// The record as an export writes it.
    public func record() -> JSONObject {
        var record = JSONObject([
            ("engine", .string(engine)), ("language", .string(language)),
            ("x-inferenceMs", .int(inferenceMs)), ("x-resumedFromMs", .int(resumedFromMs)),
        ])
        if let speakerDiarization {
            var diarization = JSONObject([("backend", .string(speakerDiarization.backend)),
                                          ("model", .string(speakerDiarization.model))])
            if let sha = speakerDiarization.sha { diarization["sha"] = .string(sha) }
            diarization["turnCount"] = .int(speakerDiarization.turnCount)
            diarization["speakerCount"] = .int(speakerDiarization.speakerCount)
            record["x-speakerDiarization"] = .object(diarization)
        }
        return record
    }
}
