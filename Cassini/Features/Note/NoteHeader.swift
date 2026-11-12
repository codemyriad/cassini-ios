import SwiftUI
import CassiniNotebook

/// The note's title and, outside reading mode, the subtitle "Today, 10:02 · 48:13".
struct NoteHeader: View {
    let note: Note
    let subtitle: NoteSubtitle?
    @Environment(\.calendar) private var calendar

    var body: some View {
        #if DEBUG
        let _ = RenderProbe.rendered("header")
        #endif
        VStack(alignment: .leading, spacing: 8) {
            Text(note.title).font(.system(.largeTitle)).foregroundStyle(Color.ink)
                .textSelection(.enabled).accessibilityAddTraits(.isHeader).accessibilityIdentifier("noteTitle")
            if let subtitle {
                Text(NoteCopy.subtitle(subtitle, calendar: calendar))
                    .font(.subheadline.monospacedDigit()).foregroundStyle(Color.muted)
                    .accessibilityIdentifier("noteSubtitle")
            }
        }
    }
}

/// The chips row of the reading content: the trust chip (a tap shows or hides the trust banner), the version chip
/// (opens the versions) and the speaker count (opens Speakers).
struct NoteChipsRow: View {
    let chips: NoteChips
    let toggleTrust: () -> Void
    let openVersions: () -> Void
    let openSpeakers: () -> Void

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
                    .background(Color.ink.opacity(0.06), in: Capsule())
            }
            .buttonStyle(.plain)
            .frame(minHeight: HitTarget.minimum)
            .accessibilityIdentifier("versionChip")
        }
        // iOS: the count opens the note's Speakers list (Android shows it as a caption).
        Button(action: openSpeakers) {
            Label(NoteCopy.speakerCount(chips.speakers), systemImage: "person.2")
                .font(.caption.weight(.medium)).foregroundStyle(Color.muted)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Color.ink.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: HitTarget.minimum)
        .accessibilityIdentifier("speakersButton")
    }
}
