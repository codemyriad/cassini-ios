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
                }
                .onOpenURL { url in
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
        }
    }
}

/// Registers the notification categories and hears notification taps from the first moment of the launch, so a tap
/// that launched Cassini is not lost.
@MainActor final class AppDelegate: NSObject, UIApplicationDelegate {
    let notifications = NotificationResponder()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = notifications
        NotificationCategory.register(in: center)
        return true
    }
}
