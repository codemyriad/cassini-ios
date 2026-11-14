import SwiftUI
import UIKit
import CassiniNotebook

/// Hero metrics. The phone headline size (`32`) is decided (`L-27`); gaps and wave dimensions are drawn values kept as
/// named constants (`COMPONENTS.md` §8).
enum FirstRunHeroMetrics {
    static let headlineSize: CGFloat = 32
    static let top: CGFloat = 20
    static let subtitleTop: CGFloat = 4
    static let qualifierTop: CGFloat = 6
    static let waveTop: CGFloat = 24
    static let waveHeight: CGFloat = 40
    static let howToTop: CGFloat = 20
    static let privacyTop: CGFloat = 10
    static let shieldSpacing: CGFloat = 6
}

/// The wave component on phones (`L-27`, `W5.2`, `COMPONENTS.md` §8): square `4 pt` teal (`accent`) bars, `4 pt` apart,
/// fading toward the trailing edge (mirrored in RTL).
enum HeroWaveMetrics {
    static let bar: CGFloat = 4
    static let gap: CGFloat = 4
    static let levels: [CGFloat] = [
        0.30, 0.55, 0.80, 0.45, 1.00, 0.65, 0.35, 0.70, 0.90, 0.50,
        0.25, 0.60, 0.85, 0.40, 0.75, 0.30, 0.55, 0.95, 0.45, 0.20,
    ]
    static let endAlpha: CGFloat = 0

    struct Bar: Equatable {
        let rect: CGRect
        let alpha: Double
    }

    static func bars(width: CGFloat, height: CGFloat, rightToLeft: Bool = false) -> [Bar] {
        let step = bar + gap
        let count = Int((width + gap) / step)
        guard count > 0, height > 0 else { return [] }
        return (0..<count).map { index in
            let fraction = count == 1 ? 0 : CGFloat(index) / CGFloat(count - 1)
            let alpha = Double(1 - (1 - endAlpha) * fraction)
            let barHeight = max(height * levels[index % levels.count], bar)
            let x = rightToLeft ? width - bar - CGFloat(index) * step : CGFloat(index) * step
            return Bar(rect: CGRect(x: x, y: (height - barHeight) / 2, width: bar, height: barHeight), alpha: alpha)
        }
    }
}

/// The Wave 5 first-run hero on an empty Library (`L-27`, `D-974`, `D98`): the headline pair, decorative wave, how-to
/// line, and backup-gated device-specific privacy line. Record and Import stay in the bottom `CaptureBar`.
struct FirstRunHeroView: View {
    let hero: FirstRunHero
    var device: FirstRunDevice = UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = FirstRunHeroMetrics.headlineSize

    var body: some View {
        let privacyText = LibraryWave5Copy.privacyLine(hero.privacy, device: device)
        VStack(alignment: .leading, spacing: 0) {
            Text(LibraryWave5Copy.heroTitle)
                .font(.system(size: headlineSize, weight: .bold))
                .foregroundStyle(Color.ink)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("heroTitle")

            if hero.cloudBackup {
                VStack(alignment: .leading, spacing: FirstRunHeroMetrics.qualifierTop) {
                    Text(LibraryWave5Copy.heroSubtitle)
                        .font(.system(size: headlineSize, weight: .bold))
                        .foregroundStyle(Color.faint)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(LibraryWave5Copy.heroPhoneBackupQualifier)
                        .font(.subheadline)
                        .foregroundStyle(Color.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, FirstRunHeroMetrics.subtitleTop)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(LibraryWave5Copy.heroSubtitlePhoneNote)
                .accessibilityAddTraits(.isStaticText)
                .accessibilityIdentifier("heroSubtitle")
            } else {
                Text(LibraryWave5Copy.heroSubtitle)
                    .font(.system(size: headlineSize, weight: .bold))
                    .foregroundStyle(Color.faint)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, FirstRunHeroMetrics.subtitleTop)
                    .accessibilityIdentifier("heroSubtitle")
            }

            HeroWave()
                .frame(maxWidth: .infinity)
                .frame(height: FirstRunHeroMetrics.waveHeight)
                .padding(.top, FirstRunHeroMetrics.waveTop)
                .accessibilityHidden(true)

            if let howTo = BannerCopy.body(.libEmpty, BannerArgs()) {
                Text(howTo)
                    .font(.subheadline)
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, FirstRunHeroMetrics.howToTop)
                    .accessibilityIdentifier("heroHowTo")
            }

            HStack(alignment: .firstTextBaseline, spacing: FirstRunHeroMetrics.shieldSpacing) {
                Image(systemName: "shield")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accent)
                    .accessibilityHidden(true)
                Text(privacyText)
                    .font(.footnote)
                    .foregroundStyle(Color.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, FirstRunHeroMetrics.privacyTop)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(privacyText)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("heroPrivacy")
        }
        .padding(.vertical, FirstRunHeroMetrics.top)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunHero")
    }
}

/// Decorative wave of square `4 pt` `accent` bars fading toward the trailing edge.
struct HeroWave: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = colorScheme
        let rtl = layoutDirection == .rightToLeft
        Canvas { context, size in
            for bar in HeroWaveMetrics.bars(width: size.width, height: size.height, rightToLeft: rtl) {
                context.fill(Path(bar.rect), with: .color(Color.accent.opacity(bar.alpha)))
            }
        }
        .accessibilityHidden(true)
    }
}
