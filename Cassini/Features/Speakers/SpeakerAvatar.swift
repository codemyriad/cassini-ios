import SwiftUI
import CassiniNotebook

/// A speaker's or a saved voice's round avatar: the placeholder number ("Speaker 3" shows 3) or the first letter of
/// the name, in the speaker's tint. A placeholder speaker is stone, "not named yet", as on Android.
struct SpeakerAvatar: View {
    let name: String
    let tint: Color
    let wash: Color
    var size: CGFloat = 40
    var showsPlaceholderNumber: Bool = true

    init(name: String, tint: Color, wash: Color, size: CGFloat = 40, showsPlaceholderNumber: Bool = true) {
        self.name = name; self.tint = tint; self.wash = wash; self.size = size
        self.showsPlaceholderNumber = showsPlaceholderNumber
    }

    /// A note's speaker or saved voice: use its canonical transcript/naming tint, never the all-speaker ordinal.
    init(name: String, tint: SpeakerTint, size: CGFloat = 40, showsPlaceholderNumber: Bool = true) {
        self.init(name: name, tint: tint.color, wash: tint.wash, size: size, showsPlaceholderNumber: showsPlaceholderNumber)
    }

    private var text: String {
        if showsPlaceholderNumber, let number = DefaultLabels.placeholderNumber(name) { return String(number) }
        return name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(wash, in: Circle())
            .accessibilityHidden(true)
    }
}
