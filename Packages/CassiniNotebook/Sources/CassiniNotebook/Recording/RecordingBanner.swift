import Foundation

/// The banners of the Recording screen. The screen shows the first of `RecordingBanner.banners`.
public enum RecordingBanner: Hashable, Sendable {
    /// "Microphone access is off": Open settings.
    case microphoneOff
    /// "Couldn't start the microphone": Try again.
    case couldNotStart
    /// "Microphone stopped working": Open note.
    case microphoneFailed
    /// "Stopped — storage almost full": Open note.
    case stoppedForSpace
    /// "Paused — another app is using audio": Resume.
    case pausedByOtherApp
    /// The input in use went away (headphones unplugged): Resume. iOS only.
    case inputLost
    /// "Storage almost full — about N min left".
    case storageLow(minutes: Int)

    public enum Tone: Int, Comparable, Sendable {
        case error, warn
        public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public enum Action: Hashable, Sendable {
        case openSettings, tryAgain, openNote, resume
    }

    public var tone: Tone {
        switch self {
        case .microphoneOff, .couldNotStart, .microphoneFailed: .error
        case .stoppedForSpace, .pausedByOtherApp, .inputLost, .storageLow: .warn
        }
    }

    public var action: Action? {
        switch self {
        case .microphoneOff: .openSettings
        case .couldNotStart: .tryAgain
        case .microphoneFailed, .stoppedForSpace: .openNote
        case .pausedByOtherApp, .inputLost: .resume
        case .storageLow: nil
        }
    }

    /// The banners for the recorder `state`, errors first. `microphoneOff` is true while microphone access is denied;
    /// `ended` is the outcome the screen still shows after the capture ended (the recorder may be idle again).
    public static func banners(state: RecordingState, microphoneOff: Bool, ended: RecordingOutcome? = nil) -> [RecordingBanner] {
        var banners: [RecordingBanner] = []
        if microphoneOff { banners.append(.microphoneOff) }
        var outcome = ended
        if outcome == nil, case .ended(_, let stateOutcome) = state { outcome = stateOutcome }
        switch outcome {
        case .stoppedForSpace: banners.append(.stoppedForSpace)
        case .microphoneFailed: banners.append(.microphoneFailed)
        case .couldNotStart: banners.append(.couldNotStart)
        case .saved, nil: break
        }
        if let active = state.activeRecording {
            switch active.pause {
            case .otherApp: banners.append(.pausedByOtherApp)
            case .routeLost: banners.append(.inputLost)
            case .user, nil: break
            }
            if case .lowStorage(let minutes) = active.warning { banners.append(.storageLow(minutes: minutes)) }
        }
        // A stable sort: within a tone, the order above.
        return banners.enumerated().sorted { ($0.element.tone, $0.offset) < ($1.element.tone, $1.offset) }.map(\.element)
    }
}
