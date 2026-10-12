import SwiftUI
import CassiniEngine

/// The Library and the stack above it: side by side on regular width, one stack on compact width. Recording covers
/// everything; app-wide errors show here, one at a time.
struct RootView: View {
    /// Restores the stack and the screens' scene storage (the library search); off for UI tests.
    var restoresNavigation = true
    @Environment(Router.self) private var router
    @Environment(ErrorPresenter.self) private var errors
    @Environment(\.horizontalSizeClass) private var sizeClass
    @SceneStorage("navigation.path") private var savedPath: Data?

    var body: some View {
        @Bindable var router = router
        Group {
            if sizeClass == .regular {
                NavigationSplitView {
                    LibraryView()
                } detail: {
                    NavigationStack(path: $router.path) {
                        ContentUnavailableView("Choose a recording", systemImage: "waveform",
                                               description: Text("Pick a recording in your library to read and listen."))
                            .background(Color.paper)
                            .routeDestinations()
                    }
                }
            } else {
                NavigationStack(path: $router.path) {
                    LibraryView().routeDestinations()
                }
            }
        }
        .fullScreenCover(item: $router.fullScreen) { _ in RecordingView() }
        .trashStopConfirmation()
        .alert("Something needs attention", isPresented: Binding(get: { errors.current != nil }, set: { if !$0, let id = errors.current?.id { errors.dismiss(id) } }),
               presenting: errors.current) { error in
            Button("OK", role: .cancel) {}
            if error.offersSettings { Button("Open Settings") { openSystemSettings() } }
        } message: { error in
            Text(error.message)
        }
        .onAppear {
            router.isSplit = sizeClass == .regular
            if restoresNavigation { router.restore(savedPath) }
        }
        .onChange(of: sizeClass) { _, size in router.isSplit = size == .regular }
        .onChange(of: router.encodedPath) { _, path in if restoresNavigation { savedPath = path } }
        .environment(\.restoresSceneState, restoresNavigation)
    }
}

private struct RouteDestination: View {
    let route: Route
    var body: some View {
        switch route {
        case .library: LibraryView()
        case .note(let id, let query, let start): NoteDetailView(noteID: id, query: query, start: start)
        case .settings: SettingsView()
        case .savedVoices: SavedVoicesView()
        case .trash: TrashView()
        case .licenses: LicensesView()
        case .modelDownload(let noteID): ModelDownloadView(noteID: noteID)
        }
    }
}

extension View {
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}
