import SwiftUI
import CassiniNotebook

/// Shared presentation, with platform rendering kept separate from persisted badge fields.
struct StatusBadgeView: View {
    let badge: BadgePresentation

    enum Metrics {
        static let minimumHeight: CGFloat = 22
        static let fontSize: CGFloat = 12
        static let horizontalPadding: CGFloat = 8
        static let verticalPadding: CGFloat = 3
        static let gap: CGFloat = 4
        static let dot: CGFloat = 6
        static let spinner: CGFloat = 10
        static let symbol: CGFloat = 11
        static let outline: CGFloat = 1
    }

    var body: some View {
        StatusPill(text: badge.text, glyph: glyph, ink: ink, fill: background,
                   glyphInk: glyphInk, outlined: badge.tint == .outline)
    }

    private var glyph: StatusPill.Glyph {
        switch badge.glyph {
        case .dot: .dot
        case .spinner: .spinner
        case .alert: .symbol("exclamationmark.circle")
        case .incoming: .symbol("tray.and.arrow.down")
        }
    }

    var glyphInk: Color { badge.kind == .transcribing && badge.glyph == .spinner ? .accent : ink }

    var ink: Color {
        switch badge.tint {
        case .red: .recordInk
        case .neutral, .outline: .ink2
        case .amber: .warnInk
        }
    }

    var background: Color {
        switch badge.tint {
        case .red: .recordTint
        case .neutral: Color.ink.opacity(0.1)
        case .amber: .warnTint
        case .outline: .canvasClear
        }
    }
}

/// The same native anatomy also renders phone-only states without adding them to the shared wire enum.
struct StatusPill: View {
    enum Glyph { case dot, spinner, symbol(String, size: CGFloat = StatusBadgeView.Metrics.symbol) }
    let text: String
    let glyph: Glyph
    let ink: Color
    let fill: Color
    var glyphInk: Color? = nil
    var outlined = false
    @ScaledMetric(relativeTo: .caption) private var fontSize = StatusBadgeView.Metrics.fontSize
    @ScaledMetric(relativeTo: .caption) private var minimumHeight = StatusBadgeView.Metrics.minimumHeight
    @ScaledMetric(relativeTo: .caption) private var horizontalPadding = StatusBadgeView.Metrics.horizontalPadding
    @ScaledMetric(relativeTo: .caption) private var verticalPadding = StatusBadgeView.Metrics.verticalPadding

    var body: some View {
        HStack(spacing: StatusBadgeView.Metrics.gap) {
            mark.foregroundStyle(glyphInk ?? ink).accessibilityHidden(true)
            Text(text).font(.system(size: fontSize, weight: .semibold)).monospacedDigit()
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(ink)
        .padding(.horizontal, horizontalPadding)
        .padding(.vertical, verticalPadding)
        .frame(minHeight: minimumHeight)
        .background(fill, in: Capsule())
        .overlay {
            if outlined { Capsule().strokeBorder(Color.line, lineWidth: StatusBadgeView.Metrics.outline) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    @ViewBuilder private var mark: some View {
        switch glyph {
        case .dot:
            Circle().frame(width: StatusBadgeView.Metrics.dot, height: StatusBadgeView.Metrics.dot)
        case .spinner:
            ProgressView().tint(glyphInk ?? ink).controlSize(.mini).dynamicTypeSize(.medium).scaleEffect(0.75)
                .frame(width: StatusBadgeView.Metrics.spinner, height: StatusBadgeView.Metrics.spinner)
        case .symbol(let name, let size):
            Image(systemName: name).font(.system(size: size, weight: .semibold))
        }
    }
}
