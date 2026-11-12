import SwiftUI

/// Draft canvas tokens from cassini-ux e244ad6a830e4ef77d87fb452143f7100c767139, brand/tokens.json; provenance is in Brand/UPSTREAM.json.
/// W1 draft preview activates the decided palette. File colourIndex mapping remains outside this preview.
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

// App and widget roles share the decided sheet. Forced-dark Recording ground still awaits L-08.
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
    static let errorFill = CassiniTokens.color(.errorFill)
    static let successFill = CassiniTokens.color(.successFill)
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

    static let unnamedSpeakerTint = CassiniTokens.color(.speaker0)
    static let unnamedSpeakerWash = CassiniTokens.color(.avatar0)
    static let speakerTints: [Color] = [CassiniTokens.Role.speaker1, .speaker2, .speaker3, .speaker4, .speaker5, .speaker6].map { CassiniTokens.color($0) }
    static let speakerWashes: [Color] = [CassiniTokens.Role.avatar1, .avatar2, .avatar3, .avatar4, .avatar5, .avatar6].map { CassiniTokens.color($0) }

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
