import SwiftUI
import CassiniNotebook

/// A speaker's or a saved voice's round avatar: the placeholder number ("Speaker 3" shows 3) or the first letter of
/// the name, in the speaker's tint. A placeholder speaker is stone, "not named yet", as on Android.
struct SpeakerAvatar: View {
    let name: String
    let tint: Color
    let wash: Color
    var size: CGFloat = 40

    init(name: String, tint: Color, wash: Color, size: CGFloat = 40) {
        self.name = name; self.tint = tint; self.wash = wash; self.size = size
    }

    /// A note's speaker: stone while it is a placeholder, else the tint of its place in the transcript.
    init(speaker name: String, ordinal: Int, size: CGFloat = 40) {
        self.init(name: name, tint: Self.tint(name: name, ordinal: ordinal), wash: Self.wash(name: name, ordinal: ordinal), size: size)
    }

    static func tint(name: String, ordinal: Int) -> Color {
        DefaultLabels.placeholderNumber(name) != nil ? .unnamedSpeakerTint : Color.speakerTints[ordinal % Color.speakerTints.count]
    }

    static func wash(name: String, ordinal: Int) -> Color {
        DefaultLabels.placeholderNumber(name) != nil ? .unnamedSpeakerWash : Color.speakerWashes[ordinal % Color.speakerWashes.count]
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
            .background(wash, in: Circle())
            .accessibilityHidden(true)
    }
}
