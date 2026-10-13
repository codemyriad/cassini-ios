import Foundation
import Observation
import CassiniEngine

/// Screens shown over everything else.
enum FullScreenRoute: String, Identifiable, Hashable {
    case recording
    var id: String { rawValue }
}

/// Where the user is: the observable home of the `ScreenStack` rules. The Library is the root of the stack (or the
/// sidebar on iPad); `path` holds the screens above it. Recording is a full-screen cover over everything. The path, the
/// sessions and the split are observed apart, so a note's search kept on each keystroke does not redraw the stack.
@MainActor @Observable final class Router {
    var path: [Route] = [] {
        didSet { update { $0.path = path } }
    }
    private(set) var sessions: [UUID: NoteSession] = [:]
    var fullScreen: FullScreenRoute?
    /// The Library is a sidebar next to the detail column.
    var isSplit = false

    private var screens: ScreenStack { ScreenStack(path: path, sessions: sessions, isSplit: isSplit) }

    /// Carries out a `ScreenStack` change, writing back only what changed.
    private func update(_ change: (inout ScreenStack) -> Void) {
        var next = screens
        change(&next)
        if next.path != path { path = next.path }
        if next.sessions != sessions { sessions = next.sessions }
    }

    /// The whole stack, Library first.
    var stack: [Route] { screens.stack }

    func show(_ route: Route) { update { $0.show(route) } }
    func push(_ route: Route) { update { $0.push(route) } }
    func session(_ noteID: UUID) -> NoteSession { screens.session(noteID) }
    func isOpen(_ noteID: UUID) -> Bool { screens.isOpen(noteID) }
    func markStarted(_ noteID: UUID) { update { $0.markStarted(noteID) } }
    func keepSearch(_ query: String?, for noteID: UUID) { update { $0.keepSearch(query, for: noteID) } }
    func openNote(_ id: UUID) { update { $0.openNote(id) } }
    func popToLibrary() { update { $0.popToLibrary() } }
    func offerModelDownload(for noteID: UUID) { update { $0.offerModelDownload(for: noteID) } }
    func close(noteID: UUID) { update { $0.close(noteID: noteID) } }
    func below(_ route: Route) -> Route? { screens.below(route) }
    func below(noteID: UUID) -> Route? { screens.below(noteID: noteID) }
    func set(_ stack: [Route]) { update { $0.set(stack) } }

    func presentRecording() { fullScreen = .recording }
    func dismissRecording() { if fullScreen == .recording { fullScreen = nil } }

    /// The stack as the scene keeps it (`ScreenStack.encodedPath`).
    var encodedPath: Data? { screens.encodedPath }
    func restore(_ data: Data?) { update { $0.restore(data) } }
}
