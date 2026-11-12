import SwiftUI

/// Draft canvas tokens from cassini-ux e4ae2217312370250a39ad83e047a186048e0a9e, brand/tokens.json; provenance is in Brand/UPSTREAM.json.
/// W1 draft preview activates decided roles and the explicit Record placeholder. Proposed hues are never loaded.
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
        case errorTint = "error-tint"
        case success
        case successTint = "success-tint"
        case warnInk = "warn-ink"
        case warnTint = "warn-tint"
        case neutralInk = "neutral-ink"
        case neutralTint = "neutral-tint"
        case highlight
        case highlightInk = "highlight-ink"
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
        return sheet.tokens.filter { ["decided", "placeholder"].contains($0.value.status) }
    }()

    static func color(_ role: Role, forcedDark: Bool = false) -> Color {
        guard let pair = values[role.rawValue] else { preconditionFailure("Missing brand role: \(role)") }
        return Color(light: rgba(forcedDark ? pair.dark : pair.light), dark: rgba(pair.dark))
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

// App roles and widget roles share this sheet. L-14 speaker hues and L-08 Recording ground stay app-local.
extension Color {
    static let ground = CassiniTokens.color(.ground)
    static let surface = CassiniTokens.color(.surface)
    static let sunken = CassiniTokens.color(.sunken)
    static let raised = CassiniTokens.color(.raised)
    static let line = CassiniTokens.color(.line)
    static let lineSoft = CassiniTokens.color(.lineSoft)
    static let ink = CassiniTokens.color(.ink)
    static let ink2 = CassiniTokens.color(.ink2)
    static let ink3 = CassiniTokens.color(.ink3)
    static let accent = CassiniTokens.color(.accent)
    static let accentStrong = CassiniTokens.color(.accentStrong)
    static let onAccent = CassiniTokens.color(.onAccent)
    static let accentInk = CassiniTokens.color(.accentInk)
    static let accentTint = CassiniTokens.color(.accentTint)
    static let record = CassiniTokens.color(.record)
    static let recordInk = CassiniTokens.color(.recordInk)
    static let recordTint = CassiniTokens.color(.recordTint)
    static let onRecord = CassiniTokens.color(.onRecord)
    static let error = CassiniTokens.color(.error)
    static let errorTint = CassiniTokens.color(.errorTint)
    static let success = CassiniTokens.color(.success)
    static let successTint = CassiniTokens.color(.successTint)
    static let warnInk = CassiniTokens.color(.warnInk)
    static let warnTint = CassiniTokens.color(.warnTint)
    static let neutralInk = CassiniTokens.color(.neutralInk)
    static let neutralTint = CassiniTokens.color(.neutralTint)
    static let highlight = CassiniTokens.color(.highlight)
    static let highlightInk = CassiniTokens.color(.highlightInk)
    static let inverse = CassiniTokens.color(.inverse)
    static let onInverse = CassiniTokens.color(.onInverse)
    static let inverseAccent = CassiniTokens.color(.inverseAccent)
    static let scrim = CassiniTokens.color(.scrim)
    static let shadow = CassiniTokens.color(.shadow)

    static let paper = ground
    static let card = surface
    static let muted = ink2
    static let faint = ink3
    static let processing = accent
    static let toneOK = success
    static let toneInfo = accentInk
    static let toneWarn = warnInk
    static let toneError = error
    static let tonePlain = neutralInk

    // Forced-dark Recording stays on its existing ground until L-08 is decided.
    static let recordingBackground = Color(red: 0.075, green: 0.12, blue: 0.14)
    static let recordingText = Color.white
    static let recordingSecondary = Color.white.opacity(0.62)
    static let recordingAccent = CassiniTokens.color(.recordInk, forcedDark: true)
    static let recordingFinish = record
    static let recordingLive = recordingAccent

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
    static let snackbarBackground = inverse
    static let snackbarText = onInverse
    static let snackbarAction = inverseAccent
}


/// The Live Activity's colours, shared with the app so `ContrastTests` checks them: the Lock Screen card is always
/// dark, whatever the appearance.
enum RecordingActivityColors {
    static let background = Color.recordingBackground
    static let live = CassiniTokens.color(.recordInk, forcedDark: true)
    static let finish = Color.record
    /// The "Recording" caption and the paused dot's ring.
    static let secondary = Color.white.opacity(0.7)
    /// Pause and Resume.
    static let button = Color.white.opacity(0.18)
}
