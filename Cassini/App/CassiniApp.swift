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
                .onOpenURL { url in
                    if RecordingLink.matches(url) { graph.recording.returnToRecording() } else { graph.imports.open(url) }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    graph.recording.appActivityChanged(isActive: phase == .active)
                    // Inactive is still on the screen (Control Center, the app switcher, a system alert).
                    if phase == .active { graph.processing.setVisible(true) }
                    if phase == .background { graph.processing.setVisible(false) }
                    if phase == .active, graph.startup.isReady { Task { _ = try? await graph.trash.purgeExpired() } }
                    if phase == .background { graph.enterBackground() }
                }
        }
    }
}
