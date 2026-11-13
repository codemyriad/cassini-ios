import SwiftUI
import CassiniNotebook

/// The meeting title, resolved date and duration, and its inline speaker names.
struct NoteHeader: View {
    let note: Note
    let subtitle: NoteSubtitle?
    var speakers: [TranscriptSpeaker] = []
    var nameSpeaker: (String) -> Void = { _ in }
    var titleVisibilityChanged: ((Bool) -> Void)? = nil
    @ScaledMetric(relativeTo: .title2) private var titleSize: CGFloat = 24
    @Environment(\.calendar) private var calendar

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.rendered("header")
        #endif
        VStack(alignment: .leading, spacing: 10) {
            observedTitle
            if let subtitle {
                Text(NoteCopy.subtitle(subtitle, calendar: calendar))
                    .font(.footnote.monospacedDigit()).foregroundStyle(Color.muted)
                    .accessibilityIdentifier("noteSubtitle")
            }
            if !speakers.isEmpty {
                MeetingHeaderSpeakers(speakers: speakers, nameSpeaker: nameSpeaker)
            }
        }
    }

    private var title: some View {
        Text(note.title).font(.system(size: titleSize, weight: .semibold)).tracking(-0.3).foregroundStyle(Color.ink)
            .textSelection(.enabled).accessibilityAddTraits(.isHeader).accessibilityIdentifier("noteTitle")
    }

    @ViewBuilder private var observedTitle: some View {
        if let titleVisibilityChanged {
            title.onGeometryChange(for: Bool.self) { proxy in
                proxy.frame(in: .scrollView(axis: .vertical)).maxY > 0
            } action: { titleVisibilityChanged($0) }
        } else {
            title
        }
    }
}

/// The chips row of the reading content: the trust chip (a tap shows or hides the trust banner), the version chip
/// (opens the versions). The names live inline in the header and Speakers stays in the actions menu.
struct NoteChipsRow: View {
    let chips: NoteChips
    let toggleTrust: () -> Void
    let openVersions: () -> Void

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { content }
            VStack(alignment: .leading, spacing: 8) { content }
        }
    }

    @ViewBuilder private var content: some View {
        if let trust = chips.trust { DocumentTrustChip(trust: trust, toggle: toggleTrust).frame(minHeight: HitTarget.minimum) }
        if let version = chips.version {
            Button(action: openVersions) {
                Label(NoteCopy.version(version), systemImage: "clock.arrow.circlepath")
                    .font(.caption.weight(.medium)).foregroundStyle(Color.ink)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.ink.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.plain)
            .frame(minHeight: HitTarget.minimum)
            .accessibilityIdentifier("versionChip")
        }
    }
}
