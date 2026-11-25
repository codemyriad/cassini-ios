import SwiftUI

extension View {
    /// Native glass on iOS 26; older systems keep a native material surface.
    @ViewBuilder func meetingGlass(cornerRadius: CGFloat) -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: RoundedRectangle(cornerRadius: cornerRadius))
        } else {
            background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius))
        }
    }

    @ViewBuilder func meetingScrollEdge() -> some View {
        if #available(iOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        } else {
            self
        }
    }

    @ViewBuilder func libraryBottomBar<Bar: View>(@ViewBuilder content: () -> Bar) -> some View {
        if #available(iOS 26.0, *) {
            safeAreaBar(edge: .bottom, spacing: 0, content: content)
        } else {
            safeAreaInset(edge: .bottom, spacing: 0, content: content)
        }
    }
}
