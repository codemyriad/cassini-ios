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
    static let surfaces: [(String, Color)] = [("paper", .paper), ("card", .card)]

    /// One line per pair a screen draws.
    static let pairs: [Pair] = {
        var pairs: [Pair] = [
            text("ink on paper", .ink, on: .paper),
            text("ink on card", .ink, on: .card),
            text("ink on a row (card at 55 % over paper)", .ink, on: .paper, Color.card.opacity(0.55)),
            text("muted on paper", .muted, on: .paper),
            text("muted on card", .muted, on: .card),
            text("muted on a row", .muted, on: .paper, Color.card.opacity(0.55)),
            text("muted on a preview match (ember 16 % on card)", .muted, on: .card, Color.ember.opacity(0.16)),
            text("ink on a preview match", .ink, on: .card, Color.ember.opacity(0.16)),
            text("faint (draft words that may change) on paper", .faint, on: .paper),
            text("ember on paper", .ember, on: .paper),
            text("ember on card", .ember, on: .card),
            text("ember on a notice card (ember 8 % on paper)", .ember, on: .paper, Color.ember.opacity(0.08)),
            text("processing on paper", .processing, on: .paper),
            text("paper on ink (selected filter)", .paper, on: .ink),
            text("paper on ember (the active word)", .paper, on: .ember),
            text("ink on a search match (warn 22 % on paper)", .ink, on: .paper, Color.toneWarn.opacity(0.22)),
            text("snackbar text on snackbar", .snackbarText, on: .snackbarBackground),
            text("snackbar action on snackbar", .snackbarAction, on: .snackbarBackground),
            text("white on ember fill (primary button)", .white, on: .emberFill),
            text("recording text on recording background", .recordingText, on: .recordingBackground),
            text("recording secondary on recording background", .recordingSecondary, on: .recordingBackground),
            text("recording secondary on a recording chip (white 8 %)", .recordingSecondary, on: .recordingBackground, Color.white.opacity(0.08)),
            text("recording accent on recording background", .recordingAccent, on: .recordingBackground),
            text("white on recording finish", .white, on: .recordingFinish),
            nonText("recording live dot on recording background", .recordingLive, on: .recordingBackground),
            nonText("info bar on its track", Tone.info.color, on: .paper, Tone.info.background, Tone.info.color.opacity(0.18)),
            text("ink on Name this speaker's question at its pulse (warn 30 % on paper)", .ink, on: .paper, Color.toneWarn.opacity(0.3)),
            text("ink on Name this speaker's question (warn 10 % on paper)", .ink, on: .paper, Color.toneWarn.opacity(0.1)),
            text("Live Activity caption on its card", RecordingActivityColors.secondary, on: RecordingActivityColors.background),
            text("Live Activity title on its card", .white, on: RecordingActivityColors.background),
            text("Live Activity warning on its card", RecordingActivityColors.live, on: RecordingActivityColors.background),
            text("Live Activity Pause on its card", .white, on: RecordingActivityColors.background, RecordingActivityColors.button),
            text("Live Activity Finish", .white, on: RecordingActivityColors.finish),
            nonText("Live Activity live dot on its card", RecordingActivityColors.live, on: RecordingActivityColors.background),
            nonText("Live Activity paused ring on its card", RecordingActivityColors.secondary, on: RecordingActivityColors.background),
        ]
        // The rows of the grouped lists (Settings, the sheets) keep the system's row background.
        for (name, color) in [("ink", Color.ink), ("muted", .muted), ("ember", .ember), ("error", .toneError)] {
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
        for (index, tint) in Color.speakerTints.enumerated() {
            for (surface, color) in surfaces {
                pairs.append(text("speaker tint \(index) on \(surface)", tint, on: color))
                pairs.append(nonText("speaker tint \(index) avatar over \(surface)", tint, on: color, tint.opacity(0.14)))
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
        let paper = Self.rgb(.paper, .dark)
        #expect(abs(paper.red - 0.075) < 0.002 && abs(paper.blue - 0.095) < 0.002)
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
