import SwiftUI
import UIKit

extension View {
    /// The title of the system back button over this screen, e.g. "Back to library"; nil keeps the system's. UIKit
    /// reads it from the screen below, so it is set there. The button stays the system's, with its swipe back; VoiceOver
    /// reads the title, and it names the screen in the button's long-press menu.
    func backButtonTitle(_ title: String?, accessibilityLabel: String? = nil) -> some View {
        background(BackButtonTitle(title: title, accessibilityLabel: accessibilityLabel).frame(width: 0, height: 0).accessibilityHidden(true))
    }
}

private struct BackButtonTitle: UIViewControllerRepresentable {
    let title: String?
    let accessibilityLabel: String?

    func makeUIViewController(context: Context) -> Controller { Controller() }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.backTitle = title
        controller.backAccessibilityLabel = accessibilityLabel
        controller.apply()
    }

    final class Controller: UIViewController {
        var backTitle: String?
        var backAccessibilityLabel: String?

        override func didMove(toParent parent: UIViewController?) {
            super.didMove(toParent: parent)
            apply()
        }

        override func viewWillAppear(_ animated: Bool) {
            super.viewWillAppear(animated)
            apply()
        }

        /// Sets the title on the navigation item of the screen below the one that holds this controller.
        func apply() {
            guard let navigation = navigationController else { return }
            var screen: UIViewController = self
            while let parent = screen.parent, parent !== navigation { screen = parent }
            guard let index = navigation.viewControllers.firstIndex(of: screen), index > 0 else { return }
            let item = navigation.viewControllers[index - 1].navigationItem
            item.backButtonTitle = backTitle
            if let backTitle, let backAccessibilityLabel {
                let back = UIBarButtonItem(title: backTitle, style: .plain, target: nil, action: nil)
                back.accessibilityLabel = backAccessibilityLabel
                item.backBarButtonItem = back
            } else {
                item.backBarButtonItem = nil
            }
        }
    }
}
