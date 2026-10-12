import Foundation
import Observation
import CassiniEngine

/// Screens shown over everything else.
enum FullScreenRoute: String, Identifiable, Hashable {
    case recording
    var id: String { rawValue }
}

/// What an open note screen did since the Library opened it, kept with the stack rather than with the view: a screen
/// that SwiftUI builds again (a size-class change, a stack rebuilt) neither runs its start action again nor loses its
/// search. It goes when the screen leaves the stack.
struct NoteSession: Hashable {
    /// The start action ran.
    var started = false
    /// The search as the screen last had it; "" once closed, nil while the screen has not touched the route's query.
    var search: String?
}

/// Where the user is. The Library is the root of the stack (or the sidebar on iPad); `path` holds the screens above it.
@MainActor @Observable final class Router {
    var path: [Route] = [] {
        didSet { sessions = sessions.filter { id, _ in isOpen(id) } }
    }
    private(set) var sessions: [UUID: NoteSession] = [:]
    var fullScreen: FullScreenRoute?
    /// The Library is a sidebar next to the detail column.
    var isSplit = false

    /// The whole stack, Library first.
    var stack: [Route] { [.library] + path }

    /// Opens a screen from the Library: in split view it replaces the detail column, else it is pushed.
    func show(_ route: Route) {
        if isSplit {
            opened(route)
            path.replace(with: [route])
        } else {
            push(route)
        }
    }

    /// Opens a screen on top of the current one.
    func push(_ route: Route) {
        opened(route)
        path.append(route)
    }

    /// A note the Library opens is a fresh screen: its start action runs and its search is the route's.
    private func opened(_ route: Route) {
        if let id = route.noteID { sessions[id] = nil }
    }

    func session(_ noteID: UUID) -> NoteSession { sessions[noteID] ?? NoteSession() }

    /// Whether the note's screen is in the stack.
    func isOpen(_ noteID: UUID) -> Bool { path.contains { $0.noteID == noteID } }

    /// The note's start action ran; a screen built again for it does not run it again.
    func markStarted(_ noteID: UUID) {
        sessions[noteID, default: NoteSession()].started = true
    }

    /// The note screen's search changed (nil: closed). The stack kept with the scene carries it instead of the
    /// route's query, so a restored screen shows the search as the user left it.
    func keepSearch(_ query: String?, for noteID: UUID) {
        sessions[noteID, default: NoteSession()].search = query ?? ""
    }

    /// Shows the note, popping to it when it is already open.
    func openNote(_ id: UUID) { set(BackStack.popOrPush(stack, .note(id))) }

    func popToLibrary() { path.removeAll() }

    /// The model download screen over the note, when the note is still the screen on top (as after a recording that
    /// may not be transcribed without the download).
    func offerModelDownload(for noteID: UUID) {
        guard path.last == .note(noteID) else { return }
        push(.modelDownload(noteID: noteID))
    }

    /// Pops the note's screen, and every screen above it, when it is open.
    func close(noteID: UUID) {
        guard let index = path.firstIndex(where: { $0.noteID == noteID }) else { return }
        path.removeSubrange(index...)
    }

    /// The screen under the topmost `route`, for its back label.
    func below(_ route: Route) -> Route? { BackStack.below(route, in: stack) }

    /// The screen under the note's, whatever query or start action the note was opened with.
    func below(noteID: UUID) -> Route? {
        stack.last { $0.noteID == noteID }.flatMap(below)
    }

    func presentRecording() { fullScreen = .recording }
    func dismissRecording() { if fullScreen == .recording { fullScreen = nil } }

    /// Replaces the stack, keeping the screens it shares at the bottom.
    func set(_ stack: [Route]) {
        var current = self.stack
        current.replace(with: BackStack.rooted(stack))
        path = Array(current.dropFirst())
    }

    /// The stack as the scene keeps it. A note's start action (an export, Document info, Rename) runs once, when the
    /// Library opens the note, so a restored stack carries none; a note's query is its search as the screen left it.
    var encodedPath: Data? { try? JSONEncoder().encode(path.map(kept)) }

    private func kept(_ route: Route) -> Route {
        guard case .note(let id, let query, _) = route else { return route }
        let search = sessions[id]?.search ?? query
        return .note(id, query: search?.isEmpty == false ? search : nil)
    }

    func restore(_ data: Data?) {
        guard path.isEmpty, let data, let restored = try? JSONDecoder().decode([Route].self, from: data) else { return }
        set(restored)
    }
}
