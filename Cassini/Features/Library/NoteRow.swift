import SwiftUI
import CassiniNotebook

/// What a row asks the Library to do.
enum NoteRowAction {
    case open, resume, rename, trash
}

/// A Library row (board 00): the title (2 lines) with the duration, the preview or search snippet (2 lines) with its
/// ellipses and highlights, and the meta line (the time, or the day and time in search results; the status chip; the
/// suffix). "· Resume" and "· Try again" are inline buttons.
///
/// For VoiceOver the row is one button described as "title, duration, day time, status[, suffix][, preview]", with
/// Resume or Try again, Rename and Move to Recently Deleted (not while recording) as named actions.
struct NoteRow: View {
    let row: LibraryRow
    /// The day of the section the row is in; search results carry their own.
    let day: DayKey
    /// The note open beside the Library in split view.
    var selected = false
    let perform: (NoteRowAction) -> Void
    @Environment(\.calendar) private var calendar
    @Environment(\.dynamicTypeSize) private var dynamicType

    var body: some View {
        let format = LibraryFormat(calendar: calendar)
        ZStack {
            // The whole card is the row's button; the texts above it let taps through, the inline suffix does not.
            Button { perform(.open) } label: { Color.compatibilityClear.contentShape(Rectangle()) }
                .buttonStyle(.plain)
                .accessibilityLabel(format.rowLabel(row, day: day))
                .accessibilityHint(LibraryCopy.openNote)
                .accessibilityIdentifier("noteRow")
                .accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityActions { accessibilityActions }
            content(format)
        }
        .background(row.highlighted || selected ? Color.card : Color.card.opacity(0.55),
                    in: RoundedRectangle(cornerRadius: Radius.card))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: Radius.card).stroke(Color.ember.opacity(0.6), lineWidth: 1.5)
                    .allowsHitTesting(false)
            } else if row.highlighted {
                RoundedRectangle(cornerRadius: Radius.card).stroke(Tone.info.color.opacity(0.35), lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
    }

    private func content(_ format: LibraryFormat) -> some View {
        let titleLayout = dynamicType.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 10))
        return VStack(alignment: .leading, spacing: 8) {
            titleLayout {
                let titleFont = Font.system(.title3, design: .serif, weight: .medium)
                Text(HighlightedText.attributed(Highlighted(row.title, ranges: row.titleRanges), font: titleFont))
                    .font(titleFont).foregroundStyle(Color.ink).lineLimit(dynamicType.isAccessibilitySize ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("rowTitle").passive()
                HStack(spacing: 6) {
                    if row.isFavorite { Image(systemName: "star.fill").font(.caption).foregroundStyle(Color.ember) }
                    Text(TimeText.clock(row.duration)).font(.subheadline.monospacedDigit()).foregroundStyle(Color.muted)
                }.fixedSize().passive()
            }
            if let preview = row.preview {
                // An excerpt by design, two lines as on Android.
                Text(HighlightedText.attributed(preview, font: .subheadline)).font(.subheadline).foregroundStyle(Color.muted)
                    .lineLimit(2).accessibilityIdentifier("rowPreview").passive()
            }
            FlowLayout(spacing: 8) {
                if let meetingTime = format.meetingTime(row) {
                    Text(meetingTime).font(.caption).foregroundStyle(Color.muted).passive()
                }
                RowChip(status: row.status).passive()
                suffix
                if row.bookmarkCount > 0 {
                    Label { Text(row.bookmarkCount, format: .number) } icon: { Image(systemName: "bookmark.fill") }.font(.caption).foregroundStyle(Color.muted).passive()
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var suffix: some View {
        if let text = LibraryCopy.suffix(row.status) {
            switch row.status.suffix {
            case .resume, .tryAgain:
                Button { perform(.resume) } label: { Text(text).font(.caption.weight(.semibold)).foregroundStyle(Color.ember) }
                    .buttonStyle(.plain)
                    .frame(minHeight: HitTarget.minimum).contentShape(Rectangle())
                    .padding(.vertical, -12)
                    .accessibilityLabel(row.status.suffix == .resume ? LibraryCopy.resumeDescription(row.title)
                        : LibraryCopy.tryAgainDescription(row.title))
            default:
                Text(text).font(.caption).foregroundStyle(Color.muted).passive()
            }
        }
    }

    @ViewBuilder private var accessibilityActions: some View {
        switch row.status.suffix {
        case .resume: Button(LibraryCopy.resume) { perform(.resume) }
        case .tryAgain: Button(LibraryCopy.tryAgain) { perform(.resume) }
        default: EmptyView()
        }
        Button(LibraryCopy.rename) { perform(.rename) }
        if !row.isRecording { Button(TrashCopy.moveToTrash) { perform(.trash) } }
    }
}

/// The status chip: text in the status's tone on its tint, never colour alone.
struct RowChip: View {
    let status: LibraryRow.Status

    var body: some View {
        HStack(spacing: 5) {
            if case .recording = status { Circle().fill(tone.color).frame(width: 6, height: 6) }
            if case .transcribed = status { Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)) }
            Text(LibraryCopy.status(status)).font(.caption.weight(.medium))
        }
        .foregroundStyle(tone.color).padding(.horizontal, 8).padding(.vertical, 4)
        .background(tone.background, in: Capsule())
    }

    private var tone: Tone { status.tone }
}

/// Highlighted text as SwiftUI draws it: each match in weight 600 on an accent tint, so it does not rely on colour.
enum HighlightedText {
    /// `font` is the text's own, so a match keeps its size.
    static func attributed(_ highlighted: Highlighted, font: Font) -> AttributedString {
        var text = AttributedString(highlighted.text)
        let characters = Array(highlighted.text)
        for range in highlighted.ranges where range.lowerBound >= 0 && range.upperBound <= characters.count {
            let start = text.index(text.startIndex, offsetByCharacters: range.lowerBound)
            let end = text.index(start, offsetByCharacters: range.count)
            text[start..<end].font = font.weight(.semibold)
            text[start..<end].foregroundColor = .ink
            text[start..<end].backgroundColor = Color.ember.opacity(0.16)
        }
        var shown = AttributedString()
        if highlighted.leadingEllipsis { shown += AttributedString("…") }
        shown += text
        if highlighted.trailingEllipsis { shown += AttributedString("…") }
        return shown
    }
}

private extension View {
    /// Drawn only: the row's button under it takes the taps and speaks for it.
    func passive() -> some View { accessibilityHidden(true).allowsHitTesting(false) }
}

/// Lays its children out in rows, wrapping to the next row when one does not fit (Android's `FlowRow`): at large
/// text sizes the suffix goes under the chip instead of out of the row.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        let rows = rows(width: proposal.width ?? .infinity, subviews)
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(0, rows.count - 1))
        let width = rows.map(\.width).max() ?? 0
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        var y = bounds.minY
        for row in rows(width: bounds.width, subviews) {
            var x = bounds.minX
            for index in row.items {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row { var items: [Int] = []; var width: CGFloat = 0; var height: CGFloat = 0 }

    private func rows(width: CGFloat, _ subviews: Subviews) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = rows[rows.count - 1].items.isEmpty ? size.width : rows[rows.count - 1].width + spacing + size.width
            if needed > width, !rows[rows.count - 1].items.isEmpty {
                rows.append(Row())
            }
            var row = rows[rows.count - 1]
            row.width = row.items.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.items.append(index)
            rows[rows.count - 1] = row
        }
        return rows.filter { !$0.items.isEmpty }
    }
}
