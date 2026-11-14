import SwiftUI
#if DEBUG
import CassiniEngineTesting
#endif

/// A snapshot of a completed app decision, exposed only by Debug UI-test launches. Tests wait for the event before
/// inspecting the screen; elapsed time is never evidence that an optional element will stay absent.
struct UITestStateMarker: View {
    let identifier: String
    var value = ""
    @Environment(\.uiTesting) private var uiTesting

    var body: some View {
        #if DEBUG
        if uiTesting {
            Color.canvasClear.frame(width: 1, height: 1).allowsHitTesting(false)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(Text(verbatim: " "))
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier("uiTestState-\(identifier)")
                .accessibilityValue(Text(verbatim: value))
        }
        #endif
    }
}

extension EnvironmentValues {
    @Entry var uiTesting = false
    #if DEBUG
    @Entry var modelInstallRecorder: FakeModelInstallRecorder? = nil
    #endif
}
