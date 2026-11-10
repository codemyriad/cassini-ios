import SwiftUI
import UIKit

/// UIKit presentation completion, scene activation and loaded data are separate events. The Library exposes this
/// marker only once all three hold, so a cold-launch test can tap once without a timed retry policy.
struct UITestInteractiveMarker: View {
    let loaded: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var presented = false

    var body: some View {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            ZStack {
                PresentationProbe { presented = $0 }.frame(width: 0, height: 0)
                if loaded, presented, scenePhase == .active {
                    Text(verbatim: " ").font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
                        .accessibilityIdentifier("uiTestState-libraryInteractive")
                }
            }
            .allowsHitTesting(false)
        }
        #endif
    }
}

private struct PresentationProbe: UIViewControllerRepresentable {
    let changed: (Bool) -> Void
    func makeUIViewController(context: Context) -> Controller { Controller(changed: changed) }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        let changed: (Bool) -> Void
        init(changed: @escaping (Bool) -> Void) { self.changed = changed; super.init(nibName: nil, bundle: nil) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); changed(true) }
        override func viewWillDisappear(_ animated: Bool) { changed(false); super.viewWillDisappear(animated) }
    }
}
