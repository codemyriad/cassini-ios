import Foundation

/// One word of a transcript as the preview reads it.
public struct PreviewWord: Hashable, Sendable {
    public var text: String
    public var startMs: Int64
    public var endMs: Int64
    /// Who says it; nil when the passage has no speaker.
    public var speaker: String?
    public var lowConfidenceSpeaker: Bool
    public init(_ text: String, startMs: Int64, endMs: Int64, speaker: String? = nil, lowConfidenceSpeaker: Bool = false) {
        self.text = text; self.startMs = startMs; self.endMs = endMs; self.speaker = speaker
        self.lowConfidenceSpeaker = lowConfidenceSpeaker
    }
}

/// A Library preview excerpt. `text` has no ellipses; `leadingEllipsis` marks an excerpt that does not start at the
/// transcript start, `trailingEllipsis` one that was cut before the transcript end.
public struct Preview: Hashable, Sendable {
    public var text: String
    public var leadingEllipsis: Bool
    public var trailingEllipsis: Bool
    public init(_ text: String, leadingEllipsis: Bool = false, trailingEllipsis: Bool = false) {
        self.text = text; self.leadingEllipsis = leadingEllipsis; self.trailingEllipsis = trailingEllipsis
    }

    /// The excerpt as shown and stored in `Note.previewText`; `Highlighted(marked:)` reads it back.
    public var display: String {
        (leadingEllipsis ? "…" : "") + text + (trailingEllipsis ? "…" : "")
    }
}

/// The Library preview of a transcript without a search query (Android `PreviewText`, features.md section 1).
///
/// When the saved playback position is after the first word and before the end of the last word, the excerpt starts
/// at the word playing at that position and has a leading ellipsis. It takes whole words and inline chips up to about `limit`
/// characters and stops at the first model row end reached once it holds at least `minBeforeTurnEnd`
/// characters, so one preview does not run two speakers' words together. A shorter turn ("Yes.") continues into the
/// next turns, so the row never shows a one-word excerpt while more words follow.
///
/// Otherwise (position 0, before the first word starts, or at or after the end of the last word, which is where a
/// finished playback leaves it) the excerpt is the transcript start: the first `limit` characters of the words joined
/// by spaces, cut at a word.
///
/// An excerpt that ends before the transcript end gets a trailing ellipsis. Stored punctuation and whole atoms stay
/// intact, as on Android. Lengths are UTF-16 units; a single oversized first atom can exceed the approximate budget.
public enum PreviewText {
    /// Approximate excerpt budget in UTF-16 units, without ellipses; an oversized first atom stays whole.
    public static let limit = 160
    /// An excerpt from the playing word stops at a turn end only once it has at least this many UTF-16 units.
    public static let minBeforeTurnEnd = 40

    /// The preview follows model reading order. Canonical indices, rather than the reordered rows' timestamps,
    /// locate the playing word; each chip word remains a separate excerpt atom at its model seam.
    public static func of(_ words: [PreviewWord], positionMs: Int64, labels: [String: String] = [:],
                          endsBoundedByAudio: Bool = false) -> Preview? {
        guard !words.isEmpty else { return nil }
        let rows = TurnModel.rows(of: words.map {
            TurnModel.Word(speaker: $0.speaker, startMs: Double($0.startMs), endMs: Double($0.endMs), text: $0.text,
                           lowConfidenceSpeaker: $0.lowConfidenceSpeaker)
        }, endsBoundedByAudio: endsBoundedByAudio)
        let speakerIDs = Set(words.compactMap(\.speaker))
        let entries = rows.enumerated().flatMap { rowIndex, row in
            row.members.flatMap { member -> [Entry] in
                let chip = member.kind == .interjection
                let id = member.speaker == "Unknown speaker" && !speakerIDs.contains("Unknown speaker") ? nil : member.speaker
                let label = chip ? id.map { labels[$0] ?? $0 } ?? SpeakerName.unknown.label : nil
                return member.wordIndices.enumerated().map { offset, index in
                    let text = words[index].text.trimmingCharacters(in: .whitespacesAndNewlines)
                    let spaced = offset == 0 || !TurnModel.matches(text, #"^[,.;:!?)]"#)
                    return Entry(text: text, canonical: index, row: rowIndex, spaceBefore: spaced,
                                 prefix: label.flatMap { offset == 0 ? "(\($0): " : nil } ?? "",
                                 suffix: chip && offset == member.wordIndices.count - 1 ? ")" : "", chipLabel: label)
                }
            }
        }
        guard !entries.isEmpty else { return nil }
        let lastEnd = words.map(\.endMs).max() ?? 0
        let playing: Int
        if positionMs <= 0 || positionMs <= (words.map(\.startMs).min() ?? 0) || positionMs >= lastEnd {
            // Unplayed notes and finished playback start in reading order, independently of source-index ties
            // or an earlier turn appended after canonical word zero.
            playing = entries[0].canonical
        } else if let active = words.indices.filter({ words[$0].startMs <= positionMs && words[$0].endMs > positionMs })
            .max(by: { words[$0].startMs == words[$1].startMs ? $0 < $1 : words[$0].startMs < words[$1].startMs }) {
            playing = active
        } else {
            playing = words.indices.filter { words[$0].startMs > positionMs }
                .min(by: { words[$0].startMs == words[$1].startMs ? $0 < $1 : words[$0].startMs < words[$1].startMs }) ?? 0
        }
        let first = entries.firstIndex { $0.canonical == playing } ?? 0
        return excerpt(entries[first...], leading: first > 0)
    }

    private struct Entry {
        var text: String
        var canonical: Int
        var row: Int
        var spaceBefore: Bool
        var prefix: String
        var suffix: String
        var chipLabel: String?
        /// A truncated chip still closes after the last whole atom, within the reserved budget.
        var closingIfCut: String { chipLabel != nil && suffix.isEmpty ? ")" : "" }
    }

    private static func excerpt(_ entries: ArraySlice<Entry>, leading: Bool) -> Preview {
        var text = ""
        var next = entries.startIndex
        while next < entries.endIndex {
            let entry = entries[next]
            // Starting part-way through a chip reintroduces its label without rewinding to earlier words.
            let prefix = next == entries.startIndex ? entry.chipLabel.map { "(\($0): " } ?? entry.prefix : entry.prefix
            let part = prefix + entry.text + entry.suffix
            let separator = next > entries.startIndex && entry.spaceBefore ? " " : ""
            let budgetReached = next > entries.startIndex
                && text.utf16.count + separator.utf16.count + part.utf16.count + entry.closingIfCut.utf16.count > limit
            let rowEnd = leading && next > entries.startIndex && text.utf16.count >= minBeforeTurnEnd
                && entry.row != entries[next - 1].row
            if budgetReached || rowEnd { break }
            text += separator + part
            next += 1
        }
        text += entries[next - 1].closingIfCut
        return Preview(text, leadingEllipsis: leading, trailingEllipsis: next < entries.endIndex)
    }

}

extension Note {
    /// The Library preview uses the complete model, so an interjection or a competing speaker is placed as it is
    /// in the note. Building a prefix before grouping could mistake a partial run for a short interjection.
    public var transcriptPreview: Preview? {
        let positionMs = Int64((playbackPosition * 1000).rounded())
        let words = transcript.flatMap(PreviewWord.of)
        let stored = Dictionary((speakers ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let passageLabels = Dictionary(transcript.compactMap { segment in
            segment.speakerID.flatMap { id in segment.speaker.map { (id, $0) } }
        }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>(), order: [String] = []
        for word in words {
            if let id = word.speaker, seen.insert(id).inserted { order.append(id) }
        }
        let labels = Dictionary(uniqueKeysWithValues: order.enumerated().map { ordinal, id in
            (id, NoteTranscripts.name(label: stored[id] ?? passageLabels[id], id: id, ordinal: ordinal).label)
        })
        return PreviewText.of(words, positionMs: positionMs, labels: labels,
                              endsBoundedByAudio: !transcript.isEmpty && transcript.allSatisfy { $0.wordEndsBoundedByAudio == true })
    }
}

extension PreviewWord {
    /// Timed words keep their stored atoms. An edited passage without word times spreads its display words over
    /// the passage, so its saved playback position can still select a preview word.
    static func of(_ segment: TranscriptSegment) -> [PreviewWord] {
        if !segment.words.isEmpty {
            return segment.words.map {
                PreviewWord($0.text, startMs: Int64(($0.start * 1000).rounded()), endMs: Int64(($0.end * 1000).rounded()),
                            speaker: segment.speakerID ?? segment.speaker, lowConfidenceSpeaker: $0.lowConfidenceSpeaker == true)
            }
        }

        let text = segment.text
        let speaker = segment.speakerID ?? segment.speaker
        let pieces = text.split(whereSeparator: \.isWhitespace)
        let length = Double(max(1, text.count))
        return pieces.map { piece in
            let range = piece.startIndex..<piece.endIndex
            let offset = Double(text.distance(from: text.startIndex, to: range.lowerBound))
            let span = segment.end - segment.start
            let start = segment.start + span * offset / length
            let end = segment.start + span * (offset + Double(piece.count)) / length
            return PreviewWord(String(piece), startMs: Int64((start * 1000).rounded()), endMs: Int64((end * 1000).rounded()),
                               speaker: speaker)
        }
    }
}
