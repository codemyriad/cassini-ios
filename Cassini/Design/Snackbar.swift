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
        .shadow(color: Color.compatibilityBlack.opacity(0.12), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityActions { if let actionTitle { Button(actionTitle, action: action) } }
    }
}
