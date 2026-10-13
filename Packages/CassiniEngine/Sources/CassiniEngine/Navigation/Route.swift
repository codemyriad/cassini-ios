import Foundation
import CassiniNotebook

/// Something the note screen does once when it opens, asked for from the Library.
public enum NoteStartAction: Codable, Hashable, Sendable {
    case export(TranscriptFormat)
    case documentInfo
    case rename

    /// What the note screen does for it.
    public var effect: NoteEffect {
        switch self {
        case .export(let format): .exportTranscript(format)
        case .documentInfo: .documentInfo
        case .rename: .rename
        }
    }
}

/// A screen in the navigation stack. Recording is a full-screen cover, not a route. Persisted in scene storage: never
/// rename a case.
public enum Route: Codable, Hashable, Sendable {
    /// The bottom of every stack.
    case library
    case note(UUID, query: String? = nil, start: NoteStartAction? = nil)
    case settings
    case savedVoices
    case trash
    case licenses
    /// Consent for the model download, before transcribing `noteID` or on its own.
    case modelDownload(noteID: UUID?)

    public var noteID: UUID? {
        if case .note(let id, _, _) = self { id } else { nil }
    }

    /// Whether both are the same screen; a note matches whatever query or start action it was opened with.
    public func isSameScreen(as other: Route) -> Bool {
        if let noteID { return noteID == other.noteID }
        return self == other
    }
}

/// The stack rules shared by deep links and in-app navigation. A stack always has the Library at its bottom.
public enum BackStack {
    /// `stack` with the Library at the bottom, and nowhere else.
    public static func rooted(_ stack: [Route]) -> [Route] {
        stack.first == .library ? stack : [.library] + stack.filter { $0 != .library }
    }

    /// Pops to the topmost `route` when the stack has it, else pushes it.
    public static func popOrPush(_ stack: [Route], _ route: Route) -> [Route] {
        let rooted = rooted(stack)
        guard let index = rooted.lastIndex(where: { $0.isSameScreen(as: route) }) else { return rooted + [route] }
        return Array(rooted[...index])
    }

    /// The screen under the topmost `route`, which picks its back label; nil when `route` is not in the stack or is
    /// at its bottom.
    public static func below(_ route: Route, in stack: [Route]) -> Route? {
        guard let index = stack.lastIndex(of: route), index > 0 else { return nil }
        return stack[index - 1]
    }
}

extension Array where Element == Route {
    /// Makes the stack equal to `target`, keeping the entries the two share at the bottom, so those screens stay.
    public mutating func replace(with target: [Route]) {
        let shared = zip(self, target).prefix { $0 == $1 }.count
        removeLast(count - shared)
        append(contentsOf: target.dropFirst(shared))
    }
}
