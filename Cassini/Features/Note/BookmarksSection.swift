import SwiftUI
import CassiniEngine
import CassiniNotebook

/// The note's marked moments (an iOS extra), in a card in the normal text colour: each shows its time, speaker and
/// words on one line, seeks to its moment, and can be removed.
struct BookmarksSection: View {
    let note: Note
    var transcript: NoteTranscript = .empty
    @Binding var isExpanded: Bool
    let model: NoteScreenModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                isExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "bookmark")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.ink)
                        .accessibilityHidden(true)
                    Text(NoteCopy.markedMoments(note.bookmarks.count))
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Color.ink)
                    Spacer(minLength: 8)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.muted)
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 14)
                .frame(minHeight: HitTarget.minimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(.isButton)
            .accessibilityIdentifier("markedMomentsToggle")

            if isExpanded {
                Divider().overlay(Color.lineSoft).padding(.horizontal, 14)
                VStack(spacing: 0) {
                    ForEach(Array(note.bookmarks.enumerated()), id: \.element.id) { index, bookmark in
                        if index > 0 {
                            Divider().overlay(Color.lineSoft).padding(.horizontal, 14)
                        }
                        bookmarkRow(bookmark)
                    }
                }
            }
        }
        .cardBackground(radius: Radius.card)
        // Cards sit 14 pt from the screen edge inside the 24 pt reading gutter.
        .padding(.horizontal, -10)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("bookmarksSection")
    }

    private func bookmarkRow(_ bookmark: Bookmark) -> some View {
        let preview = transcript.bookmarkPreview(at: bookmark.time)
        return HStack(spacing: 4) {
            Button { model.seek(bookmark.time) } label: {
                HStack(spacing: 6) {
                    Text(TimeText.clock(bookmark.time))
                        .monospacedDigit()
                        .foregroundStyle(Color.muted)
                        .fixedSize()
                    if let custom = bookmark.label, !custom.isEmpty {
                        Text(custom)
                            .foregroundStyle(Color.ink)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    } else if let preview {
                        momentSummary(speaker: preview.speaker, words: preview.words)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.leading, 14)
                .padding(.vertical, 10)
                .frame(minHeight: HitTarget.minimum)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button(NoteCopy.removeBookmark, systemImage: "minus.circle") {
                model.removeBookmark(bookmark.id)
            }
            .labelStyle(.iconOnly)
            .foregroundStyle(Color.muted)
            .frame(minWidth: HitTarget.minimum, minHeight: HitTarget.minimum)
            .padding(.trailing, 4)
        }
        .font(.subheadline)
    }

    private func momentSummary(speaker: SpeakerName?, words: String) -> Text {
        if let speaker {
            return Text(NoteCopy.speakerName(speaker)).fontWeight(.medium).foregroundStyle(Color.ink)
                + Text(verbatim: " ")
                + Text(words).foregroundStyle(Color.muted)
        }
        return Text(words).foregroundStyle(Color.ink)
    }
}
