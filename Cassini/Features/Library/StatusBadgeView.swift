import SwiftUI
import CassiniNotebook

/// W0.4's shared pill. Metrics remain named, provisional phone values from the contract.
struct StatusBadgeView: View {
    let badge: BadgePresentation

    enum Metrics {
        static let minimumHeight: CGFloat = 22
        static let horizontalPadding: CGFloat = 8
        static let gap: CGFloat = 4
        static let dot: CGFloat = 6
        static let spinner: CGFloat = 10
        static let symbol: CGFloat = 11
        static let outline: CGFloat = 1
    }

    var body: some View {
        HStack(spacing: Metrics.gap) {
            glyph.accessibilityHidden(true)
            Text(badge.text).font(.caption.weight(.semibold)).monospacedDigit()
        }
        .foregroundStyle(ink)
        .padding(.horizontal, Metrics.horizontalPadding)
        .frame(minHeight: Metrics.minimumHeight)
        .background(background, in: Capsule())
        .overlay {
            if badge.tint == .outline {
                Capsule().strokeBorder(CassiniTokens.color(.line), lineWidth: Metrics.outline)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(badge.text)
    }

    @ViewBuilder private var glyph: some View {
        switch badge.glyph {
        case .dot:
            Circle().fill(ink).frame(width: Metrics.dot, height: Metrics.dot)
        case .spinner:
            // Only the glyph has a fixed metric; the label keeps the user’s Dynamic Type size.
            ProgressView().tint(ink).dynamicTypeSize(.medium).scaleEffect(0.5)
                .frame(width: Metrics.spinner, height: Metrics.spinner)
        case .alert:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: Metrics.symbol, weight: .semibold))
        case .incoming:
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: Metrics.symbol, weight: .semibold))
        }
    }

    var ink: Color {
        let role: CassiniTokens.Role = switch badge.tint {
        case .red: .recordInk
        case .neutral, .outline: .ink2
        case .amber: .warnInk
        }
        return CassiniTokens.color(role)
    }

    var background: Color {
        switch badge.tint {
        case .red: CassiniTokens.color(.recordTint)
        case .neutral: CassiniTokens.color(.neutralTint)
        case .amber: CassiniTokens.color(.warnTint)
        case .outline: CassiniTokens.color(.ground).opacity(0)
        }
    }
}
