import Foundation

/// What the Note screen shows for a running job, as `ProgressTracker` publishes it.
public enum JobPhase: Hashable, Sendable {
    /// The job was claimed and is reading its note and checkpoint ("Starting…").
    case starting
    /// A cancelled job still holds the speech engine ("Finishing the previous note…").
    case waitingForPrevious
    /// Models are being installed before any audio is read; nil until the first progress is reported.
    case downloading(DownloadProgress?)
    /// The pipeline runs: the progress card and the draft transcript.
    case transcribing(RunningProgress, DraftState)
    /// Stop was asked: the job keeps what is finalized and ends at its next result.
    case stopping
}

/// The five columns of the progress card's stepper. On iOS speakers are told apart after the words, from the whole
/// file, so Speakers & matching is its own step after Words (Android: Words & voices, then Matching).
public enum JobStep: Int, CaseIterable, Comparable, Hashable, Sendable {
    case reading, preparing, words, speakers, saving

    public static func of(_ stage: TranscriptionStage) -> JobStep {
        switch stage {
        case .reading: .reading
        case .preparing: .preparing
        case .words: .words
        case .speakers, .matching: .speakers
        case .saving: .saving
        }
    }

    public static func < (a: JobStep, b: JobStep) -> Bool { a.rawValue < b.rawValue }
}

/// The progress card's headline.
public enum ProgressHeadline: Hashable, Sendable {
    case starting, waitingForPrevious, readingAudio, preparing, findingWords, findingSpeakers, matchingVoices, saving
}

public enum TimeLeft: Hashable, Sendable {
    /// Fewer than 3 results since the run began, or the total is unknown.
    case calculating
    /// Nothing is left but saving.
    case finishing
    /// Rounded with `TranscriptionProgress.roundedRemaining`, the finalization estimate included.
    case range(lowMs: Int64, highMs: Int64)
}

public enum BatteryLine: Hashable, Sendable {
    /// No battery reading: the cell is hidden.
    case unavailable
    /// Not enough discharge measured yet.
    case measuring(percentNow: Int)
    case pluggedIn(percentNow: Int)
    case projected(percentNow: Int, percentAtFinish: Int)
}

/// The numbers of the progress card.
public struct RunningProgress: Hashable, Sendable {
    public var headline: ProgressHeadline
    /// The audio the headline's stage works on; 0..<0 when it has none.
    public var rangeStartMs: Int64
    public var rangeEndMs: Int64
    /// 0 to 100, at most 99 until the job is done; nil while the total is unknown.
    public var percent: Int?
    public var step: JobStep
    /// The Speakers & matching step will not run in this job.
    public var speakersSkipped: Bool
    public var timeLeft: TimeLeft
    public var doneMs: Int64
    public var totalMs: Int64
    public var battery: BatteryLine
    public var words: Int
    /// A model the running step needs is being downloaded.
    public var download: DownloadProgress?
    /// The device is low on memory ("Close other apps if transcription stops").
    public var lowMemory: Bool

    public init(headline: ProgressHeadline, rangeStartMs: Int64 = 0, rangeEndMs: Int64 = 0, percent: Int?,
                step: JobStep, speakersSkipped: Bool, timeLeft: TimeLeft, doneMs: Int64, totalMs: Int64,
                battery: BatteryLine, words: Int, download: DownloadProgress? = nil, lowMemory: Bool = false) {
        self.headline = headline; self.rangeStartMs = rangeStartMs; self.rangeEndMs = rangeEndMs
        self.percent = percent; self.step = step; self.speakersSkipped = speakersSkipped; self.timeLeft = timeLeft
        self.doneMs = doneMs; self.totalMs = totalMs; self.battery = battery; self.words = words
        self.download = download; self.lowMemory = lowMemory
    }
}

/// The draft transcript of a running job. Speakers are told apart only after the words on iOS, so every draft word is
/// one voice.
public struct DraftState: Hashable, Sendable {
    public var words: [DraftWord]
    /// Words that end after this may still change; `Int64.max` once the words are final.
    public var tentativeFromMs: Int64
    /// Always false on iOS: speakers are named once the job is done.
    public var namingOpen: Bool

    public init(words: [DraftWord], tentativeFromMs: Int64, namingOpen: Bool = false) {
        self.words = words; self.tentativeFromMs = tentativeFromMs; self.namingOpen = namingOpen
    }

    public static let empty = DraftState(words: [], tentativeFromMs: 0)

    /// Whether `word` may still change.
    public func isTentative(_ word: DraftWord) -> Bool { word.endMs > tentativeFromMs }
}
