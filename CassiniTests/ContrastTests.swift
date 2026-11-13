import SwiftUI
import Testing
import CassiniNotebook
@testable import Cassini

/// WCAG 2.x contrast of the colour pairs the screens draw, resolved from the tokens in light and dark. Every text pair
/// reaches 4.5:1, every non-text pair (dots, bars, the decorative avatar initial) 3:1. A background given as layers is
/// composited bottom to top first, so a tone tint is checked on the paper or card it sits on.
// ports: ContrastTest#lightPairsMeetTheirMinimumAndTheTable (iOS tokens; no documented table to match)
// ports: ContrastTest#darkPairsMeetTheirMinimumAndTheTable
// ports: ContrastTest#recordingPairs
@MainActor @Suite struct ContrastTests {
    struct Pair: CustomStringConvertible {
        let label: String
        let minimum: Double
        let foreground: Color
        /// Bottom first; the first layer must be opaque.
        let background: [Color]
        var description: String { label }
    }

    static let text = 4.5
    static let nonText = 3.0

    static func text(_ label: String, _ foreground: Color, on background: Color...) -> Pair {
        Pair(label: label, minimum: text, foreground: foreground, background: background)
    }

    static func nonText(_ label: String, _ foreground: Color, on background: Color...) -> Pair {
        Pair(label: label, minimum: nonText, foreground: foreground, background: background)
    }

    static let groupedRow = Color(uiColor: .secondarySystemGroupedBackground)

    static let tones: [(String, Tone)] = [("ok", .ok), ("info", .info), ("warn", .warn), ("error", .error), ("plain", .plain)]
    static let surfaces: [(String, Color)] = [("paper", .paper), ("card", .card), ("meeting card", .cardRest)]

    /// One line per pair a screen draws.
    static let pairs: [Pair] = {
        var pairs: [Pair] = [
            text("ink on paper", .ink, on: .paper),
            text("ink on card", .ink, on: .card),
            text("ink on card", .ink, on: .card),
            text("muted on paper", .muted, on: .paper),
            text("muted on card", .muted, on: .card),
            text("muted on card", .muted, on: .card),
            text("ink on preview highlight", .highlightInk, on: .highlight),
            text("ink on search highlight", .highlightInk, on: .highlight),
            text("faint (draft words that may change) on paper", .faint, on: .paper),
            text("accent on paper", .accentInk, on: .paper),
            text("accent on card", .accentInk, on: .card),
            text("accent on notice tint", .accentInk, on: .accentTint),
            text("processing on paper", .processing, on: .paper),
            text("paper on ink (selected filter)", .paper, on: .ink),
            text("active word ink on highlight", .highlightInk, on: .highlight),
            text("ink on a search match (warn 22 % on paper)", .ink, on: .paper, Color.highlight),
            text("snackbar text on snackbar", .snackbarText, on: .snackbarBackground),
            text("snackbar action on snackbar", .snackbarAction, on: .snackbarBackground),
            text("primary label on accent fill", .onAccent, on: .accentStrong),
            nonText("primary busy indicator on accent fill", .onAccent, on: .accentStrong),
            text("Record label on Record fill", .onRecord, on: .record),
            text("destructive filled label", .onRecord, on: .errorFill),
            text("success filled label", .onRecord, on: .successFill),
            text("recording badge", .recordInk, on: .recordTint),
            text("recording text on recording background", .recordingText, on: .recordingBackground),
            text("recording secondary on recording background", .recordingSecondary, on: .recordingBackground),
            text("recording secondary on recording control", .recordingSecondary, on: .recordingBackground, .recordingButtonWash),
            text("recording accent on recording background", .recordingAccent, on: .recordingBackground),
            text("label on recording finish", .onRecord, on: .recordingFinish),
            nonText("recording live dot on recording background", .recordingLive, on: .recordingBackground),
            nonText("info bar on its track", Tone.info.color, on: .paper, Tone.info.background, Tone.info.color.opacity(0.18)),
            text("ink on sunken", .ink, on: .sunken),
            text("ink on Name a speaker notice pill", .ink, on: .sunken, Color.ink.opacity(0.1)),
            text("ink on Likely pill", .ink, on: .card, Color.ink.opacity(0.1)),
            text("ink on Cancel pill", .ink, on: .paper, Color.ink.opacity(0.1)),
            nonText("Name a speaker pulse ring on paper", .speaker0, on: .paper),
            nonText("Name a speaker pulse ring on sunken", .speaker0, on: .sunken),
            text("Live Activity caption on its card", RecordingActivityColors.secondary, on: RecordingActivityColors.background),
            text("Live Activity title on its card", .recordingText, on: RecordingActivityColors.background),
            text("Live Activity warning on its card", RecordingActivityColors.live, on: RecordingActivityColors.background),
            text("Live Activity Pause on its card", .recordingText, on: RecordingActivityColors.background, RecordingActivityColors.button),
            text("Live Activity Finish", .onRecord, on: RecordingActivityColors.finish),
            nonText("Live Activity live dot on its card", RecordingActivityColors.live, on: RecordingActivityColors.background),
            nonText("Live Activity paused ring on its card", RecordingActivityColors.secondary, on: RecordingActivityColors.background),
        ]
        // The rows of the grouped lists (Settings, the sheets) keep the system's row background.
        for (name, color) in [("ink", Color.ink), ("muted", .muted), ("accent", .accentInk), ("error", .toneError)] {
            pairs.append(text("\(name) on a grouped list row", color, on: Self.groupedRow))
        }
        for (name, tone) in tones {
            for (surface, color) in surfaces {
                pairs.append(text("\(name) on \(name) tint over \(surface)", tone.color, on: color, tone.background))
                pairs.append(text("ink on \(name) tint over \(surface)", .ink, on: color, tone.background))
                pairs.append(text("muted on \(name) tint over \(surface)", .muted, on: color, tone.background))
                pairs.append(nonText("\(name) dot on \(name) tint over \(surface)", tone.color, on: color, tone.background))
            }
        }
        for (index, tint) in (Color.speakerTints + [Color.unnamedSpeakerTint]).enumerated() {
            for (surface, color) in surfaces {
                pairs.append(text("speaker tint \(index) on \(surface)", tint, on: color))
                let wash = (Color.speakerWashes + [Color.unnamedSpeakerWash])[index]
                pairs.append(text("speaker tint \(index) avatar over \(surface)", tint, on: color, wash))
            }
        }
        return pairs
    }()

    @Test(arguments: [ColorScheme.light, .dark])
    func everyPairMeetsItsMinimum(_ scheme: ColorScheme) {
        let failures = Self.pairs.compactMap { pair -> String? in
            let ratio = Self.contrast(pair.foreground, on: pair.background, scheme)
            return ratio < pair.minimum ? "\(pair.label): \(String(format: "%.2f", ratio)) < \(pair.minimum)" : nil
        }
        #expect(failures.isEmpty, "\(scheme): \(failures.joined(separator: "\n"))")
    }

    /// The resolution itself: white on black is 21:1, and a token resolves to its own value in each appearance.
    @Test func theResolutionReadsTheTokens() {
        #expect(abs(Self.contrast(.white, on: [.black], .light) - 21) < 0.01)
        #expect(Self.rgb(.paper, .dark) == Self.rgb(CassiniTokens.color(.ground), .dark))
        #expect(Self.rgb(.ink, .light) != Self.rgb(.ink, .dark))
        #expect(Self.rgb(Self.groupedRow, .light) != Self.rgb(Self.groupedRow, .dark), "a system colour follows the appearance")
    }

    // MARK: WCAG

    struct RGB: Equatable { var red: Double, green: Double, blue: Double }

    static func resolved(_ color: Color, _ scheme: ColorScheme) -> Color.Resolved {
        var environment = EnvironmentValues()
        environment.colorScheme = scheme
        return color.resolve(in: environment)
    }

    static func rgb(_ color: Color, _ scheme: ColorScheme) -> RGB {
        let value = resolved(color, scheme)
        return RGB(red: Double(value.red), green: Double(value.green), blue: Double(value.blue))
    }

    /// The layers composited bottom to top, then the foreground over them.
    static func contrast(_ foreground: Color, on layers: [Color], _ scheme: ColorScheme) -> Double {
        var base = rgb(layers[0], scheme)
        precondition(resolved(layers[0], scheme).opacity == 1, "the bottom layer must be opaque")
        for layer in layers.dropFirst() { base = over(layer, base, scheme) }
        return ratio(over(foreground, base, scheme), base)
    }

    /// Source-over in sRGB, as the screen blends.
    static func over(_ color: Color, _ base: RGB, _ scheme: ColorScheme) -> RGB {
        let top = resolved(color, scheme), alpha = Double(top.opacity)
        func mix(_ value: Float, _ under: Double) -> Double { Double(value) * alpha + under * (1 - alpha) }
        return RGB(red: mix(top.red, base.red), green: mix(top.green, base.green), blue: mix(top.blue, base.blue))
    }

    static func luminance(_ color: RGB) -> Double {
        func channel(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(color.red) + 0.7152 * channel(color.green) + 0.0722 * channel(color.blue)
    }

    static func ratio(_ a: RGB, _ b: RGB) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}
