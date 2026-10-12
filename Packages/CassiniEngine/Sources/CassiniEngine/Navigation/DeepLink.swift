import Foundation

/// What a notification tap or a link asks the app to show.
public enum DeepLink: Hashable, Sendable {
    /// The Live Activity: back to the recording.
    case recording
    /// A results notification. `resume` is its Resume action: the note's transcription goes on.
    case note(UUID, resume: Bool = false)
}

/// The deep links of the app as pure functions (Android `DeepLinks`): what a notification carries, how a tap or a link
/// is read back, and the stack a note link leaves. The Library is always at the bottom.
public enum DeepLinks {
    /// The `userInfo` key of what a notification opens, and its value for a note.
    public static let openKey = "open"
    public static let openNote = "note"
    public static let noteIDKey = "noteID"
    /// The identifier of the Resume action of a paused or stopped transcription.
    public static let resumeAction = "resume"
    /// The app's URL scheme, and the hosts of its links.
    public static let scheme = "cassini"
    public static let recordingHost = "recording"
    public static let noteHost = "note"

    /// What a results notification of `noteID` carries.
    public static func userInfo(noteID: UUID) -> [String: String] {
        [openKey: openNote, noteIDKey: noteID.uuidString]
    }

    /// The link of a tapped notification with `userInfo`; `action` is the identifier of the button tapped, if any.
    /// Nil when the notification asks for nothing beyond the app.
    public static func parse(userInfo: [AnyHashable: Any], action: String? = nil) -> DeepLink? {
        guard userInfo[openKey] as? String == openNote,
              let id = (userInfo[noteIDKey] as? String).flatMap(UUID.init(uuidString:)) else { return nil }
        return .note(id, resume: action == resumeAction)
    }

    /// `cassini://recording` (the Live Activity) and `cassini://note/<id>`; nil for any other URL.
    public static func parse(url: URL) -> DeepLink? {
        guard url.scheme == scheme else { return nil }
        switch url.host() {
        case recordingHost: return .recording
        case noteHost: return url.pathComponents.dropFirst().first.flatMap(UUID.init(uuidString:)).map { .note($0) }
        default: return nil
        }
    }

    /// A note link: nothing changes when the note is on top; when it is lower in `stack`, pop to it; else push it.
    public static func note(_ stack: [Route], _ id: UUID) -> [Route] { BackStack.popOrPush(stack, .note(id)) }
}
