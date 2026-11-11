import SwiftUI
import UserNotifications
import CassiniEngine

@main struct CassiniApp: App {
    @UIApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var graph = AppGraph(environment: .resolve())
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(restoresNavigation: graph.environment.launch.restoresNavigation)
                .environment(graph)
                .tint(.ember)
                .task {
                    delegate.notifications.handler = { [graph] in graph.handle($0) }
                    await graph.start()
                    graph.launchFinished.value = true
                }
                #if DEBUG
                .overlay(alignment: .bottomLeading) {
                    if graph.environment.launch.marksLaunchFinished {
                        LaunchFinishedMarker(finished: graph.launchFinished, token: graph.environment.launch.token)
                    }
                }
                #endif
                .onOpenURL { url in
                    #if DEBUG
                    if graph.captureUITestLibraryProjection(url) { return }
                    if graph.appendUITestDraft(url) { return }
                    if let relaunch = UITestRelaunch(url: url, launchedForUITests: graph.environment.launch.marksLaunchFinished) {
                        graph = relaunch.graph(replacing: graph)
                        return
                    }
                    #endif
                    if let link = DeepLinks.parse(url: url) { graph.handle(link) } else { graph.imports.open(url) }
                }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    graph.recording.appActivityChanged(isActive: phase == .active)
                    // Inactive is still on the screen (Control Center, the app switcher, a system alert).
                    if phase == .active { graph.processing.setVisible(true); graph.becameActive() }
                    if phase == .background { graph.processing.setVisible(false) }
                    if phase == .active, graph.startup.isReady { Task { _ = try? await graph.trash.purgeExpired() } }
                    if phase == .background { graph.enterBackground() }
                }
                // A new graph (a UI-test relaunch inside the app) starts every screen, task and observer afresh.
                .id(ObjectIdentifier(graph))
        }
    }
}

/// Registers the notification categories and hears notification taps from the first moment of the launch, so a tap
/// that launched Cassini is not lost.
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    let notifications = NotificationResponder()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        #if DEBUG
        // UI tests wait for every push, sheet and alert to finish moving; without UIKit animations they appear at once.
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { UIView.setAnimationsEnabled(false) }
        #endif
        let center = UNUserNotificationCenter.current()
        center.delegate = notifications
        NotificationCategory.register(in: center)
        return true
    }
}

#if DEBUG
/// What a UI test waits for after a launch: the launch work is done (the seed is written, the library read, a fixture
/// note opened), so the test's first step cannot overtake it on a busy machine. Invisible and not hit-testable. Its
/// value is the token of the relaunch inside the app that built the graph.
private struct LaunchFinishedMarker: View {
    let finished: LaunchFinished
    /// The relaunch this graph answers (`UITestRelaunch`); empty for a launch of the process.
    let token: String

    var body: some View {
        if finished.value {
            Text(verbatim: " ").font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
                .accessibilityIdentifier("launchFinished").accessibilityValue(Text(verbatim: token))
        }
    }
}
#endif
