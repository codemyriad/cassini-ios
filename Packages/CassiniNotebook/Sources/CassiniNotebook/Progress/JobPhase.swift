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
    /// Stop was asked: the job keeps what is finalized and ends at its next result, retaining the last live figures.
    case stopping(StoppingProgress? = nil)

    public var isStopping: Bool {
        if case .stopping = self { return true }
        return false
    }
}

/// The last live progress and draft retained while a stop saves its checkpoint.
public struct StoppingProgress: Hashable, Sendable {
    public var progress: RunningProgress
    public var draft: DraftState

    public init(progress: RunningProgress, draft: DraftState) {
        self.progress = progress
        self.draft = draft
    }
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

/// The draft transcript of a running job (Android's `DraftState`). The tracker gives the words as the job made them;
/// `DraftView.build` applies the draft's names (`DraftNames`): the merges, each speaker's label, which labels came from
/// an automatic live match, and the "Is this Luca?" cards.
public struct DraftState: Hashable, Sendable {
    public var words: [DraftWord]
    /// Words that end after this may still change; `Int64.max` once the words are final.
    public var tentativeFromMs: Int64
    /// The speakers can still be named in the draft: until the job closes naming after the words.
    public var namingOpen: Bool
    /// Each shown speaker's label: the user's name, else an automatic live match's name, else the placeholder
    /// ("Speaker N", numbered by first word).
    public var labels: [String: String]
    public var colourIndices: [String: Int]
    public var provenance: [String: NoteSpeaker.Provenance]
    /// The speakers whose label is an automatic live match's name ("auto" badge).
    public var automatic: Set<String>
    /// "Is this Luca?" for placeholder speakers with a live suggestion, in the order of their latest turn.
    public var suggestions: [DraftSuggestion]

    public init(words: [DraftWord], tentativeFromMs: Int64, namingOpen: Bool = false, labels: [String: String] = [:],
                automatic: Set<String> = [], suggestions: [DraftSuggestion] = [],
                colourIndices: [String: Int] = [:], provenance: [String: NoteSpeaker.Provenance] = [:]) {
        self.words = words; self.tentativeFromMs = tentativeFromMs; self.namingOpen = namingOpen
        self.labels = labels; self.automatic = automatic; self.suggestions = suggestions
        self.colourIndices = colourIndices; self.provenance = provenance
    }

    public static let empty = DraftState(words: [], tentativeFromMs: 0)

    /// Whether `word` may still change.
    public func isTentative(_ word: DraftWord) -> Bool { word.endMs > tentativeFromMs }
}

/// A draft's "Is this Luca?" (Android's `VoiceSuggestion`): the speaker, the saved voice, its name and live score, and
/// the start of the speaker's latest turn, where the card goes.
public struct DraftSuggestion: Hashable, Sendable {
    public var speakerID: String
    public var voiceID: UUID
    public var name: String
    public var score: Float
    public var atMs: Int64

    public init(speakerID: String, voiceID: UUID, name: String, score: Float, atMs: Int64) {
        self.speakerID = speakerID; self.voiceID = voiceID; self.name = name; self.score = score; self.atMs = atMs
    }
}

extension TimeLeft {
    /// Whole minutes from the floored low end to the rounded-up high end, at least 1; nil under a minute and when the
    /// time left is not a range.
    public var minutes: ClosedRange<Int64>? {
        guard case .range(let lowMs, let highMs) = self, highMs >= 60_000 else { return nil }
        let high = (highMs + 59_999) / 60_000
        return min(max(lowMs / 60_000, 1), high)...high
    }
}
