import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
    var fill = Color.accentStrong
    var text = Color.onAccent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(text).padding(.horizontal, 22).padding(.vertical, 17)
            .frame(maxWidth: .infinity).background(fill, in: Capsule()).opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct RecordButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(Color.onRecord)
            .padding(.horizontal, 22).padding(.vertical, 17)
            .frame(minWidth: 160).background(Color.record, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}
