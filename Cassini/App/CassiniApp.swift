import SwiftUI

@main struct CassiniApp: App {
    @State private var graph = AppGraph(environment: .resolve())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(restoresNavigation: graph.environment.launch.restoresNavigation)
                .environment(graph)
                .tint(.ember)
                .task { await graph.start() }
                .onOpenURL { url in Task { await graph.imports.importAudio(url) } }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active, graph.startup.isReady { Task { await graph.trash.purgeExpired() } }
                    if phase == .background { graph.playback.savePosition() }
                }
        }
    }
}
