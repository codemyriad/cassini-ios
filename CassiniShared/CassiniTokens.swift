import SwiftUI

/// Draft canvas tokens from cassini-ux e244ad6a830e4ef77d87fb452143f7100c767139, brand/tokens.json; provenance is in Brand/UPSTREAM.json.
/// W1.1 installs these roles without activating them. Existing output remains in the compatibility block below;
/// the separate W1 look-preview PR switches call sites, including the now-decided speaker/avatar roles.
enum CassiniTokens {
    enum Role: String, CaseIterable {
        case ground
        case surface
        case sunken
        case raised
        case line
        case lineSoft = "line-soft"
        case ink
        case ink2 = "ink-2"
        case ink3 = "ink-3"
        case accent
        case accentStrong = "accent-strong"
        case onAccent = "on-accent"
        case accentInk = "accent-ink"
        case accentTint = "accent-tint"
        case record
        case recordInk = "record-ink"
        case recordTint = "record-tint"
        case onRecord = "on-record"
        case error
        case errorFill = "error-fill"
        case errorTint = "error-tint"
        case success
        case successFill = "success-fill"
        case successTint = "success-tint"
        case warnInk = "warn-ink"
        case warnTint = "warn-tint"
        case neutralInk = "neutral-ink"
        case neutralTint = "neutral-tint"
        case highlight
        case highlightInk = "highlight-ink"
        case speaker0 = "speaker-0"
        case speaker1 = "speaker-1"
        case speaker2 = "speaker-2"
        case speaker3 = "speaker-3"
        case speaker4 = "speaker-4"
        case speaker5 = "speaker-5"
        case speaker6 = "speaker-6"
        case avatar0 = "avatar-0"
        case avatar1 = "avatar-1"
        case avatar2 = "avatar-2"
        case avatar3 = "avatar-3"
        case avatar4 = "avatar-4"
        case avatar5 = "avatar-5"
        case avatar6 = "avatar-6"
        case inverse
        case onInverse = "on-inverse"
        case inverseAccent = "inverse-accent"
        case scrim
        case shadow
    }
    private struct Value: Decodable, Sendable { let light: String; let dark: String; let status: String }
    private struct Sheet: Decodable { let tokens: [String: Value] }
    private final class BundleAnchor: NSObject {}
    static let bundle = Bundle(for: BundleAnchor.self)
    private static let values: [String: Value] = {
        guard let file = bundle.url(forResource: "tokens", withExtension: "json"),
              let data = try? Data(contentsOf: file),
              let sheet = try? JSONDecoder().decode(Sheet.self, from: data) else {
            preconditionFailure("The pinned brand token resource is missing or invalid")
        }
        return sheet.tokens.filter { $0.value.status == "decided" }
    }()

    static func color(_ role: Role) -> Color {
        guard let pair = values[role.rawValue] else { preconditionFailure("Missing brand role: \(role)") }
        return Color(light: rgba(pair.light), dark: rgba(pair.dark))
    }

    private static func rgba(_ hex: String) -> UIColor {
        let text = hex.dropFirst()
        guard hex.first == "#", [6, 8].contains(text.count), let bits = UInt32(text, radix: 16) else {
            preconditionFailure("Invalid brand colour: \(hex)")
        }
        let rgba = text.count == 6 ? (bits << 8) | 255 : bits
        return UIColor(red: CGFloat((rgba >> 24) & 255) / 255, green: CGFloat((rgba >> 16) & 255) / 255,
                       blue: CGFloat((rgba >> 8) & 255) / 255, alpha: CGFloat(rgba & 255) / 255)
    }
}

// Compatibility colours retain the exact pre-W1 floating-point values (not rounded hex values).
// Kept app-local until the preview activates each role; Recording ground still awaits L-08.
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

extension Color {
    /// The snackbar is ink on paper turned around; its action keeps at least 4.5:1 on it in both appearances.
    static let snackbarBackground = Color.ink
    static let snackbarText = Color.paper
    static let snackbarAction = Color(light: UIColor(red: 1, green: 0.62, blue: 0.48, alpha: 1),
                                      dark: UIColor(red: 0.62, green: 0.16, blue: 0.05, alpha: 1))
}


/// The Live Activity's colours, shared with the app so `ContrastTests` checks them: the Lock Screen card is always
/// dark, whatever the appearance.
enum RecordingActivityColors {
    static let background = Color(red: 0.075, green: 0.12, blue: 0.14)
    static let live = Color(red: 0.98, green: 0.49, blue: 0.30)
    static let finish = Color(red: 0.78, green: 0.24, blue: 0.12)
    /// The "Recording" caption and the paused dot's ring.
    static let secondary = Color.white.opacity(0.7)
    /// Pause and Resume.
    static let button = Color.white.opacity(0.18)
}
