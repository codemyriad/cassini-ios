import SwiftUI
import CassiniNotebook

/// The palette: the warm Cassini brand colours plus tone tints for status and notices. Every token has a light and a
/// dark value, and every pair the screens draw meets WCAG AA in both (`ContrastTests`): 4.5:1 for text, 3:1 for large
/// text and non-text.
extension Color {
    static let paper = Color(light: rgb(0.975, 0.965, 0.941), dark: rgb(0.075, 0.085, 0.095))
    static let card = Color(light: .white, dark: rgb(0.12, 0.135, 0.145))
    static let ink = Color(light: rgb(0.12, 0.17, 0.19), dark: rgb(0.95, 0.94, 0.91))
    static let muted = Color(light: rgb(0.34, 0.38, 0.40), dark: rgb(0.67, 0.71, 0.73))
    /// Lighter than `muted`, still readable: the words of a draft that may change.
    static let faint = Color(light: rgb(0.40, 0.44, 0.46), dark: rgb(0.56, 0.60, 0.62))
    static let ember = Color(light: rgb(0.72, 0.21, 0.095), dark: rgb(1, 0.49, 0.32))
    /// Ember as a fill under white text (the primary button): the dark ember is too light for it.
    static let emberFill = Color(light: rgb(0.72, 0.21, 0.095), dark: rgb(0.78, 0.24, 0.12))

    /// The Recording screen is always dark.
    static let recordingBackground = Color(red: 0.075, green: 0.12, blue: 0.14)
    static let recordingText = Color.white
    /// Captions and the paused state on the Recording screen and the Library's recording card.
    static let recordingSecondary = Color.white.opacity(0.62)
    static let recordingAccent = Color(red: 0.98, green: 0.49, blue: 0.30)
    static let recordingFinish = Color(red: 0.78, green: 0.24, blue: 0.12)
    static let recordingLive = Color.orange
    static let processing = Color(light: rgb(0.10, 0.36, 0.70), dark: rgb(0.45, 0.66, 1))

    /// Tone tints: text and icons in a tone; their backgrounds use `Tone.background`.
    static let toneOK = Color(light: rgb(0.13, 0.40, 0.35), dark: rgb(0.40, 0.80, 0.72))
    static let toneInfo = processing
    static let toneWarn = Color(light: rgb(0.55, 0.35, 0.02), dark: rgb(0.98, 0.76, 0.36))
    static let toneError = ember
    static let tonePlain = muted

    /// Speaker tints, assigned by first appearance in a transcript.
    static let speakerTints: [Color] = [
        Color(light: rgb(0.76, 0.22, 0.10), dark: rgb(1, 0.55, 0.40)),
        Color(light: rgb(0.10, 0.40, 0.62), dark: rgb(0.48, 0.72, 0.95)),
        Color(light: rgb(0.20, 0.45, 0.22), dark: rgb(0.52, 0.82, 0.55)),
        Color(light: rgb(0.48, 0.27, 0.62), dark: rgb(0.78, 0.62, 0.95)),
        Color(light: rgb(0.60, 0.38, 0.02), dark: rgb(0.98, 0.76, 0.36)),
        Color(light: rgb(0.05, 0.45, 0.47), dark: rgb(0.40, 0.82, 0.84)),
    ]

    private static func rgb(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> UIColor {
        UIColor(red: red, green: green, blue: blue, alpha: 1)
    }

    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }
}

extension Tone {
    var color: Color {
        switch self {
        case .ok: .toneOK
        case .info: .toneInfo
        case .warn: .toneWarn
        case .error: .toneError
        case .plain: .tonePlain
        }
    }

    var background: Color { color.opacity(0.09) }
}

enum Radius {
    static let chip: CGFloat = 8
    static let field: CGFloat = 14
    static let control: CGFloat = 16
    static let card: CGFloat = 20
}

enum Spacing {
    static let tight: CGFloat = 8
    static let row: CGFloat = 12
    static let card: CGFloat = 18
    static let section: CGFloat = 26
    static let gutter: CGFloat = 24
}

/// The widest a screen's content gets on a wide window, Android's `MaxContentWidth`: every screen caps its content
/// at it, centred, and its background still fills the window. On a phone it changes nothing.
enum ReadableWidth {
    static let content: CGFloat = 560
}

extension View {
    /// Caps the content at `ReadableWidth.content`, centred in the width it gets.
    func readableWidth() -> some View {
        frame(maxWidth: ReadableWidth.content).frame(maxWidth: .infinity)
    }

    /// Caps a list's or form's rows at `ReadableWidth.content` with side margins, so the list still scrolls (and
    /// shows its indicator) across the window.
    func readableListWidth() -> some View { modifier(ReadableListWidth()) }
}

private struct ReadableListWidth: ViewModifier {
    @State private var geometry = Geometry()

    /// The list's visible width and the insets beside it: in a split view the detail column's list runs under the
    /// sidebar, which is its leading safe-area inset.
    private struct Geometry: Equatable {
        var width: CGFloat = 0
        var leading: CGFloat = 0
        var trailing: CGFloat = 0
    }

    /// Below this the list keeps its own margins (a phone).
    private static let minimumMargin: CGFloat = 20

    func body(content: Content) -> some View {
        let margin = (geometry.width - ReadableWidth.content) / 2
        Group {
            if margin > Self.minimumMargin {
                content
                    .contentMargins(.leading, geometry.leading + margin, for: .scrollContent)
                    .contentMargins(.trailing, geometry.trailing + margin, for: .scrollContent)
            } else {
                content
            }
        }
        .onGeometryChange(for: Geometry.self) { proxy in
            Geometry(width: proxy.size.width, leading: proxy.safeAreaInsets.leading, trailing: proxy.safeAreaInsets.trailing)
        } action: { geometry = $0 }
    }
}

/// The smallest tap target.
enum HitTarget {
    static let minimum: CGFloat = 44
}
