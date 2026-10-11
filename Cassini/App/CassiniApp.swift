import SwiftUI

@main struct CassiniApp: App {
    @State private var store = AppStore()
    @Environment(\.scenePhase) private var scenePhase
    var body: some Scene {
        WindowGroup {
            LibraryView().environment(store).tint(.ember)
                .task { await store.recoverInterruptedWork() }
                .onOpenURL { url in Task { await store.importAudio(url) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { store.purgeExpiredTrash() }
                    if phase == .background, let id = store.player.noteID {
                        store.update(id) { $0.playbackPosition = store.player.position }
                    }
                }
        }
    }
}
