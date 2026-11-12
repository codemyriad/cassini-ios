import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(Color.compatibilityWhite).padding(.horizontal, 22).padding(.vertical, 17)
            .frame(maxWidth: .infinity).background(Color.emberFill, in: Capsule()).opacity(configuration.isPressed ? 0.75 : 1)
    }
}
