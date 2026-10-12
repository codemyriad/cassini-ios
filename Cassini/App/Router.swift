import Foundation
import Observation
import CassiniEngine

/// Screens shown over everything else.
enum FullScreenRoute: String, Identifiable, Hashable {
    case recording
    var id: String { rawValue }
}

/// Where the user is. The Library is the root of the stack (or the sidebar on iPad); `path` holds the screens above it.
@MainActor @Observable final class Router {
    var path: [Route] = []
    var fullScreen: FullScreenRoute?
    /// The Library is a sidebar next to the detail column.
    var isSplit = false

    /// The whole stack, Library first.
    var stack: [Route] { [.library] + path }

    /// Opens a screen from the Library: in split view it replaces the detail column, else it is pushed.
    func show(_ route: Route) {
        if isSplit { path.replace(with: [route]) } else { push(route) }
    }

    /// Opens a screen on top of the current one.
    func push(_ route: Route) { path.append(route) }

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

    func presentRecording() { fullScreen = .recording }
    func dismissRecording() { if fullScreen == .recording { fullScreen = nil } }

    /// Replaces the stack, keeping the screens it shares at the bottom.
    func set(_ stack: [Route]) {
        var current = self.stack
        current.replace(with: BackStack.rooted(stack))
        path = Array(current.dropFirst())
    }

    var encodedPath: Data? { try? JSONEncoder().encode(path) }

    func restore(_ data: Data?) {
        guard path.isEmpty, let data, let restored = try? JSONDecoder().decode([Route].self, from: data) else { return }
        set(restored)
    }
}
