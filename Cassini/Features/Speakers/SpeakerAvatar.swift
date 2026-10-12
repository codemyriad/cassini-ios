import SwiftUI
import CassiniNotebook

/// A speaker's or a saved voice's round avatar: the placeholder number ("Speaker 3" shows 3) or the first letter of
/// the name, in the speaker's tint. A placeholder speaker is amber, "not named yet", as on Android.
struct SpeakerAvatar: View {
    let name: String
    let tint: Color
    var size: CGFloat = 40

    init(name: String, tint: Color, size: CGFloat = 40) {
        self.name = name; self.tint = tint; self.size = size
    }

    /// A note's speaker: amber while it is a placeholder, else the tint of its place in the transcript.
    init(speaker name: String, ordinal: Int, size: CGFloat = 40) {
        self.init(name: name, tint: Self.tint(name: name, ordinal: ordinal), size: size)
    }

    static func tint(name: String, ordinal: Int) -> Color {
        DefaultLabels.placeholderNumber(name) != nil ? .toneWarn : Color.speakerTints[ordinal % Color.speakerTints.count]
    }

    private var text: String {
        if let number = DefaultLabels.placeholderNumber(name) { return String(number) }
        return name.trimmingCharacters(in: .whitespaces).first.map { String($0).uppercased() } ?? "?"
    }

    var body: some View {
        Text(text)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.14), in: Circle())
            .accessibilityHidden(true)
    }
}
