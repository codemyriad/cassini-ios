import CassiniCore
import Foundation
import CassiniNotebook

public struct TranscriptionRequest: Hashable, Sendable {
    public var url: URL
    /// BCP-47, for Apple Speech; Parakeet ignores it.
    public var language: String
    /// Where in the audio Apple Speech begins, for a resumed job. Result times stay on the recording's clock.
    public var startOffset: TimeInterval
    /// Where a resumed Parakeet run goes on from: the checkpoint's window and its words. Nil for a fresh run.
    public var resume: TranscriptResume?
    /// Whether a missing speech model may be downloaded.
    public var allowDownload: Bool
    /// The streaming speakers a Parakeet run gives each window's words to, on its inference thread, before it
    /// reports the window; nil when the run does not tell speakers apart as it goes. Apple Speech ignores it.
    public var speakers: WindowSpeakers?
    public init(url: URL, language: String, startOffset: TimeInterval = 0, resume: TranscriptResume? = nil,
                allowDownload: Bool, speakers: WindowSpeakers? = nil) {
        self.url = url; self.language = language; self.startOffset = startOffset; self.resume = resume
        self.allowDownload = allowDownload; self.speakers = speakers
    }
}

extension WindowSpeakers: Hashable {
    public static func == (lhs: WindowSpeakers, rhs: WindowSpeakers) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}

/// A Parakeet checkpoint to go on from: `IncrementalTranscript`'s window and every word so far.
public struct TranscriptResume: Hashable, Sendable {
    public var recognition: RecognitionCheckpoint
    public var words: [Word]
    public init(recognition: RecognitionCheckpoint, words: [Word]) { self.recognition = recognition; self.words = words }
}

/// Parakeet after a 28 s window: every word so far on the recording clock (seams reconciled, not yet gated as a
/// whole), where the run can go on from, and the decode time this run.
public struct TranscriptWindow: Hashable, Sendable {
    public var words: [Word]
    public var recognition: RecognitionCheckpoint
    /// Milliseconds spent decoding windows since this run began, the model load left out.
    public var inferenceMs: Int64
    /// The streaming speakers after this window (`WindowSpeakers.checkpoint`), saved with its words.
    public var speakers: SpeakerCheckpoint?
    public init(words: [Word], recognition: RecognitionCheckpoint, inferenceMs: Int64, speakers: SpeakerCheckpoint? = nil) {
        self.words = words; self.recognition = recognition; self.inferenceMs = inferenceMs; self.speakers = speakers
    }
}

public enum TranscriptionEvent: Hashable, Sendable {
    /// The speech model is being prepared or downloaded; the fraction is nil while unknown.
    case preparingModel(Double?)
    /// Audio up to `done` seconds of `total` is transcribed.
    case progress(done: TimeInterval, total: TimeInterval)
    /// A result that will not change any more.
    case finalized(TranscriptSegment)
    /// The words heard after the last finalized result so far; they may still change. Nil when there are none.
    case volatile(TranscriptSegment?)
    /// Parakeet decoded a window; it replaces every word before it. Apple Speech never sends it.
    case window(TranscriptWindow)
}

public struct TranscriptionResult: Hashable, Sendable {
    /// In time order. For Parakeet every word of the recording, which replaces what the windows said.
    public var segments: [TranscriptSegment]
    /// Parakeet's `x-segmentation`: how the recording was cut. Nil for Apple Speech.
    public var segmentation: String?
    /// Parakeet's decode time this run, in milliseconds. Nil for Apple Speech, whose job counts the analyzer's time.
    public var inferenceMs: Int64?
    /// The streaming speakers after the last window, when the run told them apart.
    public var speakers: SpeakerCheckpoint?
    public init(segments: [TranscriptSegment], segmentation: String? = nil, inferenceMs: Int64? = nil,
                speakers: SpeakerCheckpoint? = nil) {
        self.segments = segments; self.segmentation = segmentation; self.inferenceMs = inferenceMs
        self.speakers = speakers
    }
}

public enum TranscriptionError: Error, Hashable {
    case failed(JobFailure)
    /// The speech model is missing and downloading it was not allowed.
    case needsConsent
}

/// A transcriber that read its input to the end reports `.progress(done: total, total: total)` before it returns; one
/// that cannot read the input to the end throws `TranscriptionError.failed(.open)` rather than returning what it has.
public protocol Transcribing: Sendable {
    /// The recognizer behind this transcriber: the job checks a checkpoint against it and writes its provenance.
    var recognizer: SpeechRecognizer { get }
    /// How a run would cut the recording now (Parakeet's `x-segmentation`); nil for Apple Speech.
    func segmentation() async -> String?
    func transcribe(_ request: TranscriptionRequest,
                    events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult
    func assetStatus(locale: Locale) async -> ModelPartStatus
    /// Downloads and installs the speech model for `locale` now, as the model download screen's Download does,
    /// reporting the fraction done and then Checking files (Parakeet; Apple's assets report only the fraction). Does
    /// nothing when it is installed or not offered for `locale`; a failed download or install throws
    /// `TranscriptionError.failed(.download(_))`, and a cancelled one `CancellationError`. Cancelling the caller
    /// ends its wait: an install that another caller (a job) waits on goes on, and the files fetched so far stay.
    func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws
    /// The free space the speech model's install asks for before its first byte ("Free about N MB"): Parakeet's
    /// `ModelPlan` figure, or the estimate for Apple's assets, whose size iOS does not tell.
    var assetInstallBytes: Int64 { get }
    /// The languages the speech model can transcribe here, each marked when its assets are installed.
    func speechLanguages() async -> [SpeechLanguage]
    /// The speech model that transcribes `locale` here, as the provenance's `model` names it; nil when unknown.
    func modelName(locale: Locale) async -> String?
    /// The BCP-47 tag of the language a run asked for `requested` transcribes in (Apple Speech's equivalent supported
    /// locale, such as `it-IT` for `it`); nil when the recognizer does not say which language it heard (Parakeet).
    /// The run's words are written in it (`TranscriptLanguage.ofRun`).
    func runLanguage(requested: String) async -> String?
}

extension Transcribing {
    public func modelName(locale: Locale) async -> String? { nil }
    /// The requested language for a recognizer that is given one, else nil.
    public func runLanguage(requested: String) async -> String? {
        recognizer.usesLanguage && !requested.isEmpty ? requested : nil
    }
    public var recognizer: SpeechRecognizer { .appleSpeech }
    public func segmentation() async -> String? { nil }
    public var assetInstallBytes: Int64 { ModelDownloadPlan.speechInstallBytes }
}

/// A language of speech the transcriber offers.
public struct SpeechLanguage: Hashable, Sendable {
    /// BCP-47, as `SettingsStore.speechLanguage` stores it.
    public var id: String
    /// Its speech assets are on the device.
    public var installed: Bool
    public init(id: String, installed: Bool) { self.id = id; self.installed = installed }
}
