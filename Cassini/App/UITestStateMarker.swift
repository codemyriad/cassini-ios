import SwiftUI

/// A snapshot of a completed app decision, exposed only by Debug UI-test launches. Tests wait for the event before
/// inspecting the screen; elapsed time is never evidence that an optional element will stay absent.
struct UITestStateMarker: View {
    let identifier: String
    var value = ""
    @Environment(\.uiTesting) private var uiTesting

    var body: some View {
        #if DEBUG
        if uiTesting {
            Text(verbatim: " ").font(.system(size: 1)).opacity(0.01).allowsHitTesting(false)
                .accessibilityIdentifier("uiTestState-\(identifier)").accessibilityValue(Text(verbatim: value))
        }
        #endif
    }
}

extension EnvironmentValues {
    @Entry var uiTesting = false
}
