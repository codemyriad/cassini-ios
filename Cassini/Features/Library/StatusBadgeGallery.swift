#if DEBUG
import SwiftUI
import CassiniNotebook

/// Synthetic screenshot fixture using the actual component and production selector; never a release route.
struct StatusBadgeGallery: View {

    private var badges: [BadgePresentation] {
        let text: StatusBadges.Text = { StatusBadgeCopy.template($0) }
        let meetings: [BadgeFields] = [
            .init(lifecycle: .recording, liveMs: 768_000), .init(lifecycle: .saving),
            .init(transcript: .running, etaMinutes: 4), .init(error: .init(action: "retry")),
            .init(interruptedAtMs: 2_472_000), .init(origin: .received)
        ]
        return meetings.compactMap { StatusBadges.meeting($0, text: text) }
            + [StatusBadges.entry(importing: true, text: text)].compactMap { $0 }
            + [StatusBadges.transcribing(etaMinutes: 0, text: text),
               StatusBadges.transcribing(etaMinutes: nil, text: text)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text(verbatim: "Status badges").font(.title.weight(.semibold))
                ForEach(Array(badges.enumerated()), id: \.offset) { index, badge in
                    FlowLayout {
                        StatusBadgeView(badge: badge).accessibilityIdentifier("badge-gallery-\(index)")
                    }
                }
                Text(StatusBadges.interruptedAt(position: "00:41:12",
                                                text: { StatusBadgeCopy.template($0) }))
                    .font(.caption).foregroundStyle(CassiniTokens.color(.ink2))
            }
            .frame(maxWidth: .infinity, alignment: .leading).padding(24)
            .accessibilityIdentifier("badgeGallery")
        }
        .foregroundStyle(CassiniTokens.color(.ink))
        .background(CassiniTokens.color(.ground))
    }
}
#endif
