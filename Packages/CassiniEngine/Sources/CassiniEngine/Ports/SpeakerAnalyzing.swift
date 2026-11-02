import CassiniCore
import Foundation
import CassiniNotebook

/// What a speaker step found: turns, one CAM++ print per speaker, and, when the job told the speakers apart word by
/// word as it went (the streaming diarizer of a Parakeet run), the transcript with them.
public struct SpeakerAnalysis: Hashable, Sendable {
    /// The diarizer's turns on the recording clock. Their ids are the words' ids in `transcript` when there is one,
    /// else ids of the analysis's own, which the note puts in a namespace of its own.
    public var turns: [SpeakerTurn]
    public var prints: [SpeakerPrint]
    /// The note's words with their speakers (`Diarization.assign` per window); nil when the note attributes its
    /// words itself from `turns` (an analysis of a transcript that has its words already).
    public var transcript: [TranscriptSegment]?
    /// The time the diarizer itself took, without the model install or the voiceprints.
    public var elapsedMs: Int64?
    /// The turns came from the streaming diarizer's windows (`x-incrementalDiarization`).
    public var streaming: Bool
    /// The voiceprint model was there to make prints, even when no speaker had enough speech for one
    /// (`x-speakerIdentification` is written).
    public var printsReady: Bool
    /// The draft names of a streaming run, as naming closed: their merges are applied to `turns`, `prints` and
    /// `transcript` already; the labels, rejections and Remember choices go into the note with them.
    public var names: DraftNames?

    public init(turns: [SpeakerTurn], prints: [SpeakerPrint], transcript: [TranscriptSegment]? = nil,
                elapsedMs: Int64? = nil, streaming: Bool = true, printsReady: Bool? = nil, names: DraftNames? = nil) {
        self.turns = turns; self.prints = prints; self.transcript = transcript; self.elapsedMs = elapsedMs
        self.streaming = streaming; self.printsReady = printsReady ?? !prints.isEmpty; self.names = names
    }
}

/// How far a model install has got.
public enum InstallProgress: Hashable, Sendable {
    /// The files are being fetched: the fraction done, nil while unknown.
    case downloading(Double?)
    /// Every file is checked before it is used ("Checking files").
    case checking
}

public enum SpeakerAnalysisEvent: Hashable, Sendable {
    /// Speaker models are being loaded, downloaded or checked.
    case preparingModels(InstallProgress)
    case analyzing(Double)
}

/// Why the speaker models are not there for an analysis or a standalone install.
public enum SpeakerAnalysisError: Error, Hashable, Sendable {
    /// The models are missing and downloading them was not allowed; nothing touched the network.
    case needsConsent
    /// The install failed. `requiredFreeBytes` is what the space check asked for ("Free about N MB"), else 0.
    case download(DownloadError, requiredFreeBytes: Int64)
}

/// The speaker models (Nemotron Sortformer and CAM++, `ModelPart.speakers` and `.voices`) and what runs on them. One
/// install runs at a time: a request that arrives while one runs joins it.
public protocol SpeakerAnalyzing: Sendable {
    /// Tells apart the speakers of the transcript `words` of the recording at `url` (a speakers-only job, or a
    /// transcription by Apple Speech): the streaming diarizer over the whole file in 28 s windows, then a CAM++ print
    /// per speaker. Installs the models first when they are missing and `allowDownload`, else throws
    /// `SpeakerAnalysisError.needsConsent`. A failed install throws `SpeakerAnalysisError.download`.
    func analyze(url: URL, words: [Word], allowDownload: Bool,
                 progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis
    /// The native models a Parakeet run tells speakers apart with while it decodes; nil while the diarizer is not
    /// installed or this build has no native runtime.
    func streamingEngines() async -> (any SpeakerEngines)?
    /// Whether the voiceprint model (CAM++) is installed, so a run can keep clips and make prints.
    func printsReady() async -> Bool
    /// The stored status of the models: what the last check or install found, or the install that runs.
    func modelStatus() async -> ModelPartStatus
    /// Checks the installed files again (at launch, and when Settings opens) and returns the new status.
    func refreshModelStatus() async -> ModelPartStatus
    /// Downloads and installs the models now (the model download screen's standalone Download, or a job before its
    /// decode), or joins the install that runs, reporting how far it has got. Does nothing when they are installed;
    /// a failed install throws `SpeakerAnalysisError.download`. Cancelling the caller ends its wait: an install that
    /// another caller waits on goes on, and the files fetched so far, partial ones too, stay for the next install.
    func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws
    /// The free space an install of the models asks for before its first byte; the model download screen asks for the
    /// same.
    var modelInstallBytes: Int64 { get }
}

extension SpeakerAnalyzing {
    public func streamingEngines() async -> (any SpeakerEngines)? { nil }
    public func printsReady() async -> Bool { await modelStatus() == .ready }
}

/// Streaming Sortformer, as Android's `SortformerStream` behind its `StreamingDiarizer` seam: one instance keeps the
/// speaker slots across windows. It belongs to the thread that made it (the inference thread), and releases its native
/// model when it goes.
public protocol StreamingDiarizer: AnyObject {
    /// Every turn so far, on the recording clock.
    var turns: [DiarizerTurn] { get }
    /// Milliseconds spent in native diarization.
    var elapsedMs: Int64 { get }
    /// The turns of one 16 kHz window of at most 28 s that starts at `startMs`, on the window's clock.
    func process(_ audio: PcmAudio, startMs: Int64) throws -> [DiarizerTurn]
    /// The checkpoint's diarizer state.
    var state: DiarizerState { get }
}

/// A speaker's L2-normalised CAM++ print and the seconds of speech behind it.
public struct Voiceprint: Hashable, Sendable {
    public var vector: [Float]
    public var seconds: Double
    public init(vector: [Float], seconds: Double) { self.vector = vector; self.seconds = seconds }
}

/// The native speaker models (Android's `DiarizerFactory` and `PrintExtractor`). `openDiarizer` and `prints` block the
/// calling thread, which is the inference thread: during a decode the transcriber's, otherwise `run`'s.
public protocol SpeakerEngines: Sendable {
    /// A new diarizer, or one that goes on from `restored`.
    func openDiarizer(restored: DiarizerState?) throws -> any StreamingDiarizer
    /// One CAM++ print per speaker from its `windows` of `audio`; a speaker without usable speech has none. Loads and
    /// releases the model. `active` is called between native calls and throws to stop.
    func prints(_ audio: any PcmSource, windows: [String: [PrintWindow]],
                active: () throws -> Void) throws -> [String: Voiceprint]
    /// Runs `body` on the inference thread, where the native models live.
    func run<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value
}

/// The native speaker models of the build (CassiniSherpa's `SherpaRuntime.speakers` in the app): `linked` false when
/// it has no native runtime, and then both makers throw.
public struct SpeakerRuntime: Sendable {
    public var linked: Bool
    /// A streaming Sortformer over the model file, new or going on from a saved state.
    public var makeDiarizer: @Sendable (_ model: URL, _ restored: DiarizerState?) throws -> any StreamingDiarizer
    /// CAM++ prints over the model file (Android's `VoiceprintExtractor.compute`).
    public var prints: @Sendable (_ model: URL, _ audio: any PcmSource, _ windows: [String: [PrintWindow]],
                                  _ active: () throws -> Void) throws -> [String: Voiceprint]

    public init(linked: Bool,
                makeDiarizer: @escaping @Sendable (URL, DiarizerState?) throws -> any StreamingDiarizer,
                prints: @escaping @Sendable (URL, any PcmSource, [String: [PrintWindow]], () throws -> Void) throws
                    -> [String: Voiceprint]) {
        self.linked = linked; self.makeDiarizer = makeDiarizer; self.prints = prints
    }
}

/// The prints a job keeps: every one must be `VoiceprintModel.dimension` long (Android's `VoiceprintPrints`), so a
/// wrong model file never reaches matching. The job treats the failure as "no names".
public enum CheckedPrints {
    public struct WrongDimension: Error, Hashable, Sendable, CustomStringConvertible {
        public var speaker: String
        public var count: Int
        public init(speaker: String, count: Int) { self.speaker = speaker; self.count = count }
        public var description: String {
            "Voiceprint of \(speaker) has \(count) values, expected \(VoiceprintModel.dimension)"
        }
    }

    public static func check(_ prints: [String: Voiceprint]) throws -> [String: Voiceprint] {
        for (speaker, print) in prints.sorted(by: { $0.key < $1.key }) where print.vector.count != VoiceprintModel.dimension {
            throw WrongDimension(speaker: speaker, count: print.vector.count)
        }
        return prints
    }
}
