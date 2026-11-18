import SwiftUI
import UIKit
import CassiniNotebook

/// D105 / L-70–71: normal letter spacing, a 44-point conversation wave and one shared 16-point edge.
enum FirstRunHeroMetrics {
    static let headlineSize: CGFloat = 28
    static let subtitleTop: CGFloat = 4
    static let waveHeight: CGFloat = 44
    static let sectionSpacing: CGFloat = 18
    static let shieldSpacing: CGFloat = 6
    static let gutter: CGFloat = 16
}

/// The four phrases and three pauses drawn in P2FirstRun-Phones (17 November).
/// Resampling the whole conversation preserves the pauses on a narrow iPad sidebar or a wide window.
enum HeroWaveMetrics {
    static let bar: CGFloat = 3
    static let gap: CGFloat = 3
    static let levels: [CGFloat] = [
        8, 26, 15, 28, 26, 28, 31, 18, 23, 16, 9, 14, 27, 14, 9, 7, 7, 7, 12,
        12, 18, 15, 16, 16, 20, 19, 18, 24, 20, 15, 24, 24, 19, 11, 7,
        27, 32, 27, 16, 14, 20, 16, 30, 38, 24, 34, 16, 7, 7, 7,
        11, 12, 12, 12, 11, 7, 7, 7, 7,
    ]
    static let opacities: [Double] = [
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0.87, 0.79, 0.78, 0.82, 0.92,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0.86, 0.79,
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0.96, 0.82, 0.76, 0.76,
        0.82, 0.84, 0.79, 0.74, 0.69, 0.64, 0.60, 0.55, 0.50,
    ]

    struct Bar: Equatable {
        let rect: CGRect
        let alpha: Double
    }

    static func bars(width: CGFloat, height: CGFloat, rightToLeft: Bool = false) -> [Bar] {
        guard width.isFinite, height.isFinite, width >= bar, height > 0 else { return [] }
        let count = Int((width + gap) / (bar + gap))
        return (0..<count).map { index in
            let fraction = count == 1 ? 0 : CGFloat(index) / CGFloat(count - 1)
            let sample = Int((fraction * CGFloat(levels.count - 1)).rounded())
            let barHeight = min(height, max(height * levels[sample] / 44, bar))
            let offset = fraction * (width - bar)
            let x = rightToLeft ? width - bar - offset : offset
            return Bar(rect: CGRect(x: x, y: (height - barHeight) / 2, width: bar, height: barHeight),
                       alpha: opacities[sample])
        }
    }
}

/// D105 first run has the same copy with backup on or off. Settings retains its full D98 privacy variants.
struct FirstRunHeroView: View {
    var device: FirstRunDevice = UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    @ScaledMetric(relativeTo: .largeTitle) private var headlineSize: CGFloat = FirstRunHeroMetrics.headlineSize
    @ScaledMetric(relativeTo: .callout) private var howToSize: CGFloat = 16

    var body: some View {
        let privacyText = device == .pad ? LibraryWave5Copy.firstRunPrivacyIpad : LibraryWave5Copy.firstRunPrivacyIphone
        VStack(alignment: .leading, spacing: FirstRunHeroMetrics.sectionSpacing) {
            HeroWave()
                .frame(height: FirstRunHeroMetrics.waveHeight)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: FirstRunHeroMetrics.subtitleTop) {
                Text(LibraryWave5Copy.heroTitle)
                    .foregroundStyle(Color.ink)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("heroTitle")
                Text(device == .pad ? LibraryWave5Copy.heroSubtitleIpad : LibraryWave5Copy.heroSubtitleIphone)
                    .foregroundStyle(Color.faint)
                    .accessibilityIdentifier("heroSubtitle")
            }
            .font(.system(size: headlineSize, weight: .bold))
            .fixedSize(horizontal: false, vertical: true)

            Text(SettingsPhase2Copy.firstRunHowTo)
                .font(.system(size: howToSize))
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("heroHowTo")

            HStack(alignment: .firstTextBaseline, spacing: FirstRunHeroMetrics.shieldSpacing) {
                Image(systemName: "shield")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.accent)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(privacyText)
                    Text(LibraryWave5Copy.firstRunPrivacyBackups)
                }
                .font(.footnote)
                .foregroundStyle(Color.muted)
                .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(privacyText + "\n" + LibraryWave5Copy.firstRunPrivacyBackups)
            .accessibilityAddTraits(.isStaticText)
            .accessibilityIdentifier("heroPrivacy")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("firstRunHero")
    }
}

/// Decorative neutral-grey conversation, mirrored in RTL; red stays reserved for recording.
struct HeroWave: View {
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let _ = colorScheme
        let rtl = layoutDirection == .rightToLeft
        Canvas { context, size in
            for bar in HeroWaveMetrics.bars(width: size.width, height: size.height, rightToLeft: rtl) {
                context.fill(Path(roundedRect: bar.rect, cornerRadius: HeroWaveMetrics.bar / 2),
                             with: .color(Color.faint.opacity(bar.alpha)))
            }
        }
        .accessibilityHidden(true)
    }
}
