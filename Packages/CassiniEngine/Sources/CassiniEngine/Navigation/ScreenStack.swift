import Foundation

/// What an open note screen did since the Library opened it, kept with the stack rather than with the view: a screen
/// that SwiftUI builds again (a size-class change, a stack rebuilt) neither runs its start action again nor loses its
/// search. It goes when the screen leaves the stack.
public struct NoteSession: Hashable, Sendable {
    /// The start action ran.
    public var started = false
    /// The search as the screen last had it; "" once closed, nil while the screen has not touched the route's query.
    public var search: String?

    public init(started: Bool = false, search: String? = nil) {
        self.started = started
        self.search = search
    }
}

/// The screens above the Library and the sessions of the open note screens: how the Library,
/// deep links and the screens change the stack, and what the scene keeps of it. The app's `Router` holds one.
public struct ScreenStack: Hashable, Sendable {
    /// The screens above the Library. A note screen's session goes when the screen leaves it.
    public var path: [Route] = [] {
        didSet { sessions = sessions.filter { id, _ in isOpen(id) } }
    }
    public private(set) var sessions: [UUID: NoteSession] = [:]
    /// The Library is a sidebar next to the detail column.
    public var isSplit = false

    public init(path: [Route] = [], sessions: [UUID: NoteSession] = [:], isSplit: Bool = false) {
        self.path = path
        self.sessions = sessions.filter { id, _ in path.contains { $0.noteID == id } }
        self.isSplit = isSplit
    }

    /// The whole stack, Library first.
    public var stack: [Route] { [.library] + path }

    /// Opens a screen from the Library: in split view it replaces the detail column, else it is pushed.
    public mutating func show(_ route: Route) {
        if isSplit {
            opened(route)
            path.replace(with: [route])
        } else {
            push(route)
        }
    }

    /// Opens a screen on top of the current one.
    public mutating func push(_ route: Route) {
        opened(route)
        path.append(route)
    }

    /// A note the Library opens is a fresh screen: its start action runs and its search is the route's.
    private mutating func opened(_ route: Route) {
        if let id = route.noteID { sessions[id] = nil }
    }

    public func session(_ noteID: UUID) -> NoteSession { sessions[noteID] ?? NoteSession() }

    /// Whether the note's screen is in the stack.
    public func isOpen(_ noteID: UUID) -> Bool { path.contains { $0.noteID == noteID } }

    /// The note's start action ran; a screen built again for it does not run it again.
    public mutating func markStarted(_ noteID: UUID) {
        sessions[noteID, default: NoteSession()].started = true
    }

    /// The note screen's search changed (nil: closed). The stack kept with the scene carries it instead of the
    /// route's query, so a restored screen shows the search as the user left it.
    public mutating func keepSearch(_ query: String?, for noteID: UUID) {
        sessions[noteID, default: NoteSession()].search = query ?? ""
    }

    /// Shows the note, popping to it when it is already open.
    public mutating func openNote(_ id: UUID) { set(BackStack.popOrPush(stack, .note(id))) }

    public mutating func popToLibrary() { path.removeAll() }

    /// The model download screen over the note, when the note is still the screen on top (as after a recording that
    /// may not be transcribed without the download).
    public mutating func offerModelDownload(for noteID: UUID) {
        guard path.last == .note(noteID) else { return }
        push(.modelDownload(noteID: noteID))
    }

    /// Pops the note's screen, and every screen above it, when it is open.
    public mutating func close(noteID: UUID) {
        guard let index = path.firstIndex(where: { $0.noteID == noteID }) else { return }
        path.removeSubrange(index...)
    }

    /// The screen under the topmost `route`, for its back label.
    public func below(_ route: Route) -> Route? { BackStack.below(route, in: stack) }

    /// The screen under the note's, whatever query or start action the note was opened with.
    public func below(noteID: UUID) -> Route? {
        stack.last { $0.noteID == noteID }.flatMap(below)
    }

    /// Replaces the stack, keeping the screens it shares at the bottom.
    public mutating func set(_ stack: [Route]) {
        var current = self.stack
        current.replace(with: BackStack.rooted(stack))
        path = Array(current.dropFirst())
    }

    /// The stack as the scene keeps it. A note's start action (an export, Document info, Rename) runs once, when the
    /// Library opens the note, so a restored stack carries none; a note's query is its search as the screen left it.
    public var encodedPath: Data? { try? JSONEncoder().encode(path.map(kept)) }

    private func kept(_ route: Route) -> Route {
        guard case .note(let id, let query, _) = route else { return route }
        let search = sessions[id]?.search ?? query
        return .note(id, query: search?.isEmpty == false ? search : nil)
    }

    /// Brings back the stack the scene kept, unless screens are open already or it cannot be read.
    public mutating func restore(_ data: Data?) {
        guard path.isEmpty, let data, let restored = try? JSONDecoder().decode([Route].self, from: data) else { return }
        set(restored)
    }
}
