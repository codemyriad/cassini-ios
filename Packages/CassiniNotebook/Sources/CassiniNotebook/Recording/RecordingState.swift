import Foundation

/// The format a capture writes, for the format chip ("PCM 48 kHz").
public struct CaptureFormat: Codable, Hashable, Sendable {
    public var codec: String
    public var sampleRate: Double
    public var channels: Int
    public var bitDepth: Int?
    public init(codec: String, sampleRate: Double, channels: Int, bitDepth: Int? = nil) {
        self.codec = codec; self.sampleRate = sampleRate; self.channels = channels; self.bitDepth = bitDepth
    }
    public static let pcm48kMono = CaptureFormat(codec: "PCM", sampleRate: 48_000, channels: 1, bitDepth: 16)
}

public enum RecordingPause: String, Codable, Hashable, Sendable {
    case user
    /// Another app took the audio session (a call, an alarm).
    case otherApp
    /// The input in use went away (headphones unplugged).
    case routeLost
}

public enum RecordingWarning: Hashable, Sendable {
    /// Storage runs out in about this many minutes.
    case lowStorage(minutesLeft: Int)
}

public enum RecordingOutcome: Hashable, Sendable {
    case saved
    case stoppedForSpace
    case microphoneFailed
    case couldNotStart
}

public struct ActiveRecording: Hashable, Sendable {
    public var noteID: UUID
    public var title: String
    public var defaultTitle: String
    public var format: CaptureFormat
    public var elapsed: TimeInterval
    public var pause: RecordingPause?
    /// Recording time the free space still allows.
    public var spaceLeft: TimeInterval?
    public var warning: RecordingWarning?

    public init(noteID: UUID, title: String, defaultTitle: String, format: CaptureFormat, elapsed: TimeInterval = 0,
                pause: RecordingPause? = nil, spaceLeft: TimeInterval? = nil, warning: RecordingWarning? = nil) {
        self.noteID = noteID; self.title = title; self.defaultTitle = defaultTitle; self.format = format
        self.elapsed = elapsed; self.pause = pause; self.spaceLeft = spaceLeft; self.warning = warning
    }
}

/// The recording life cycle: idle → starting → active → finishing → ended → idle.
public enum RecordingState: Hashable, Sendable {
    case idle
    case starting
    case active(ActiveRecording)
    /// The capture stopped; the note's audio is being sealed and compressed.
    case finishing(noteID: UUID)
    case ended(noteID: UUID?, outcome: RecordingOutcome)

    public var activeRecording: ActiveRecording? {
        if case .active(let recording) = self { recording } else { nil }
    }
    public var isActive: Bool { activeRecording != nil }
    public var noteID: UUID? {
        switch self {
        case .idle, .starting: nil
        case .active(let recording): recording.noteID
        case .finishing(let noteID): noteID
        case .ended(let noteID, _): noteID
        }
    }
}

/// What the Live Activity shows. Shared with the widget extension, which imports only CassiniNotebook.
public struct RecordingActivityState: Codable, Hashable, Sendable {
    public var title: String
    /// The wall-clock start of the running interval, for `Text(timerInterval:)`; nil while paused.
    public var runningSince: Date?
    public var elapsed: TimeInterval
    public var isPaused: Bool
    public var warning: String?
    public init(title: String, runningSince: Date?, elapsed: TimeInterval, isPaused: Bool, warning: String? = nil) {
        self.title = title; self.runningSince = runningSince; self.elapsed = elapsed; self.isPaused = isPaused; self.warning = warning
    }
}
