import Foundation

/// The Library's notes with what the rows and the search derive from each, worked out once per version of the note:
/// the preview, the speaker count, whether it has words, and (at the first search) its tokens. `update` keeps the
/// entries of the notes that did not change, so a library of a thousand notes filters as the user types.
public struct LibraryIndex: Sendable {
    public struct Entry: Sendable {
        public let note: Note
        /// The row's preview without a query: the one at the saved position, from the transcript shown now. The
        /// stored `previewText` is read only for a note without a transcript to compute one from (an older note), so
        /// a new version, a picked version or an edit shows at once, as Android refreshes `preview` with the body.
        public let preview: Highlighted?
        public let speakerCount: Int
        public let hasWords: Bool
        fileprivate var fields: SearchFields?

        init(_ note: Note) {
            self.note = note
            preview = note.transcriptPreview.map {
                Highlighted($0.text, leadingEllipsis: $0.leadingEllipsis, trailingEllipsis: $0.trailingEllipsis)
            } ?? LibraryMapping.storedPreview(note.previewText)
            speakerCount = Set(note.transcript.compactMap { $0.speakerID ?? $0.speaker }).count
            hasWords = note.transcript.contains { $0.text.contains { !$0.isWhitespace } }
        }
    }

    /// A note the search found, with its marked snippets (Android `SearchRow`).
    public struct Hit: Sendable {
        public let entry: Entry
        /// The transcript around the match, marked; no marks when only the title or a bookmark matched.
        public let snippet: String
        public let titleSnippet: String
        /// `snippet` read, when it has a match; nil when only the title or a bookmark matched.
        public let markedSnippet: Highlighted?
        /// `titleSnippet` read.
        public let markedTitle: Highlighted

        /// Reads the snippets here, where the search runs (off the main actor), so building the rows only copies them.
        init(entry: Entry, snippet: String, titleSnippet: String) {
            self.entry = entry; self.snippet = snippet; self.titleSnippet = titleSnippet
            markedSnippet = snippet.contains(Highlighted.matchStart) ? Highlighted(marked: snippet) : nil
            markedTitle = Highlighted(marked: titleSnippet)
        }

        /// The same hit for the note's entry now (it did not change since).
        func with(_ entry: Entry) -> Hit {
            Hit(entry: entry, snippet: snippet, titleSnippet: titleSnippet, markedSnippet: markedSnippet, markedTitle: markedTitle)
        }

        private init(entry: Entry, snippet: String, titleSnippet: String, markedSnippet: Highlighted?, markedTitle: Highlighted) {
            self.entry = entry; self.snippet = snippet; self.titleSnippet = titleSnippet
            self.markedSnippet = markedSnippet; self.markedTitle = markedTitle
        }
    }

    /// The notes outside Recently Deleted in catalogue input order. Display ordering is calendar-dependent
    /// (`orderedEntries`), so an unzoned label never receives an invented instant here.
    public private(set) var entries: [Entry] = []
    /// Changes whenever a note is added, changed, moved or removed, so a search knows its results are out of date.
    public private(set) var revision = 0
    private var cache: [UUID: Entry] = [:]

    public init(_ notes: [Note] = []) { update(notes) }

    /// Takes the notes as they are now (newest first), keeping what was worked out for the unchanged ones.
    public mutating func update(_ notes: [Note]) {
        var next: [UUID: Entry] = [:]
        next.reserveCapacity(notes.count)
        var changed = false
        let updated = notes.compactMap { note -> Entry? in
            guard note.trashedAt == nil else { return nil }
            let kept = cache[note.id].flatMap { $0.note == note ? $0 : nil }
            if kept == nil { changed = true }
            let entry = kept ?? Entry(note)
            next[note.id] = entry
            return entry
        }
        if changed || updated.map(\.note.id) != entries.map(\.note.id) { revision += 1 }
        entries = updated
        cache = next
    }

    /// Takes the tokens another copy of the index worked out (a search run elsewhere) for the notes that did not
    /// change since.
    public mutating func adoptTokens(from other: LibraryIndex) {
        for index in entries.indices where entries[index].fields == nil {
            guard let theirs = other.cache[entries[index].note.id], let fields = theirs.fields,
                  theirs.note == entries[index].note else { continue }
            entries[index].fields = fields
            cache[entries[index].note.id] = entries[index]
        }
    }

    /// The UI's ordering uses its explicit calendar; source/cache order never assigns an instant to local labels.
    public static func orderedEntries(_ entries: [Entry], calendar: Calendar) -> [Entry] {
        MeetingOrder.sorted(entries, calendar: calendar, note: \.note)
    }

    /// A search keeps its matching/snippet work, then applies the same calendar ordering as day sections.
    public static func orderedHits(_ hits: [Hit], calendar: Calendar) -> [Hit] {
        MeetingOrder.sorted(hits, calendar: calendar, note: { $0.entry.note })
    }

    public func entry(_ id: UUID) -> Entry? { cache[id] }

    /// `hits` (of `query`, from an earlier copy of the index) over the notes as they are now: a note that went is
    /// dropped, and a note that changed is matched again on its own, so a row never shows a trashed note or an old
    /// title while the search over the new notes runs.
    public func current(_ hits: [Hit], query: SearchQuery?) -> [Hit] {
        hits.compactMap { hit in
            guard let entry = cache[hit.entry.note.id] else { return nil }
            if entry.note == hit.entry.note { return hit.with(entry) }
            guard let query else { return Hit(entry: entry, snippet: "", titleSnippet: entry.note.title) }
            let fields = entry.fields ?? SearchFields(entry.note)
            guard fields.matches(query) else { return nil }
            return Hit(entry: entry, snippet: fields.snippet(query), titleSnippet: fields.titleSnippet(query))
        }
    }

    /// The notes that match every phrase of `query` in index order; every note when there is no query (only
    /// punctuation was typed). `orderedHits` supplies the viewer-calendar order without repeating matching work.
    public mutating func search(_ query: SearchQuery?) -> [Hit] {
        guard let query else { return entries.map { Hit(entry: $0, snippet: "", titleSnippet: $0.note.title) } }
        var hits: [Hit] = []
        for index in entries.indices {
            // A search replaced by a newer one stops early; its caller drops what it found.
            if index % 64 == 0, Task.isCancelled { break }
            let fields = entries[index].fields ?? SearchFields(entries[index].note)
            if entries[index].fields == nil {
                entries[index].fields = fields
                cache[entries[index].note.id] = entries[index]
            }
            guard fields.matches(query) else { continue }
            hits.append(Hit(entry: entries[index], snippet: fields.snippet(query), titleSnippet: fields.titleSnippet(query)))
        }
        return hits
    }
}
