import SwiftUI

/// A short message at the bottom of a screen, with at most one action: inverted colours, radius 14, a 44 pt action.
/// VoiceOver reads the message and offers the action both as the button and as an action of the message.
struct Snackbar: View {
    let message: String
    var actionTitle: String?
    var action: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Text(message).font(.subheadline).foregroundStyle(Color.snackbarText)
                .frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
            if let actionTitle {
                Button(action: action) {
                    Text(actionTitle).font(.subheadline.weight(.semibold)).foregroundStyle(Color.snackbarAction)
                        .padding(.horizontal, 14).frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 16).padding(.trailing, actionTitle == nil ? 16 : 6).padding(.vertical, 6)
        .frame(minHeight: 56)
        .background(Color.snackbarBackground, in: RoundedRectangle(cornerRadius: 14))
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityActions { if let actionTitle { Button(actionTitle, action: action) } }
    }
}

extension Color {
    /// The snackbar is ink on paper turned around; its action keeps at least 4.5:1 on it in both appearances.
    static let snackbarBackground = Color.ink
    static let snackbarText = Color.paper
    static let snackbarAction = Color(light: UIColor(red: 1, green: 0.62, blue: 0.48, alpha: 1),
                                      dark: UIColor(red: 0.62, green: 0.16, blue: 0.05, alpha: 1))
}
