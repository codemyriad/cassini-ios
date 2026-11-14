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
    /// The split view's columns below iOS 26 (see `body`).
    @State private var columns: NavigationSplitViewVisibility = .all
    #if DEBUG
    @Environment(\.showsBadgeGallery) private var showsBadgeGallery
    #endif

    var body: some View {
        @Bindable var router = router
        Group {
            #if DEBUG
            if showsBadgeGallery { StatusBadgeGallery() } else { navigation }
            #else
            navigation
            #endif
        }
        .fullScreenCover(item: $router.fullScreen) { _ in RecordingView() }
        .trashStopConfirmation()
        .alert(RootCopy.errorTitle, isPresented: Binding(get: { errors.current != nil }, set: { if !$0, let id = errors.current?.id { errors.dismiss(id) } }),
               presenting: errors.current) { error in
            Button(RootCopy.ok, role: .cancel) {}
            if error.offersSettings { Button(RootCopy.openSettings) { openSystemSettings() } }
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

    @ViewBuilder private var navigation: some View {
        @Bindable var router = router
        if sizeClass == .regular {
            if #available(iOS 26.0, *) {
                NavigationSplitView { LibraryView() } detail: { detail(path: $router.path) }
            } else {
                // iPadOS 18 needs both columns and the balanced style to keep the Library beside the note.
                NavigationSplitView(columnVisibility: $columns) { LibraryView() } detail: { detail(path: $router.path) }
                    .navigationSplitViewStyle(.balanced)
            }
        } else {
            NavigationStack(path: $router.path) { LibraryView().routeDestinations() }
        }
    }

    private func detail(path: Binding<[Route]>) -> some View {
        NavigationStack(path: path) {
            ContentUnavailableView(RootCopy.chooseRecording, systemImage: "waveform",
                                   description: Text(RootCopy.chooseRecordingBody))
                .background(Color.paper)
                .routeDestinations()
        }
    }
}

private struct RouteDestination: View {
    let route: Route
    @Environment(Router.self) private var router
    @Environment(NoteScreens.self) private var notes
    @Environment(\.modelRoot) private var modelRoot

    var body: some View {
        screen.navigationBarBackButtonHidden(router.hidesBackButton(route))
    }

    @ViewBuilder private var screen: some View {
        switch route {
        case .library: LibraryView()
        case .note(let id, let query, _):
            // Split-view selection replaces a destination at the same stack depth. Its state belongs to this note.
            NoteDetailView(model: notes.model(id, query: query)).id(id)
        case .settings: SettingsView()
        case .savedVoices: SavedVoicesView()
        case .trash: TrashView()
        case .licenses: LicensesView(models: modelRoot)
        case .backupInfo: BackupInfoView()
        case .modelDownload(let noteID, let part): ModelDownloadView(noteID: noteID, part: part).id(route)
        case .parakeetDownload: ModelDownloadView(noteID: nil, parakeetOnly: true)
        }
    }
}

extension View {
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { RouteDestination(route: $0) }
    }
}
