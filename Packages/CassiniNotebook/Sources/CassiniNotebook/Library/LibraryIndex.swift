import Foundation

/// The Library's notes with what the rows and the search derive from each, worked out once per version of the note:
/// the preview, the speaker count, whether it has words, and (at the first search) its tokens. `update` keeps the
/// entries of the notes that did not change, so a library of a thousand notes filters as the user types.
public struct LibraryIndex: Sendable {
    public struct Entry: Sendable {
        public let note: Note
        /// The row's preview without a query: the stored one, or the one at the saved position.
        public let preview: Highlighted?
        public let speakerCount: Int
        public let hasWords: Bool
        fileprivate var fields: SearchFields?

        init(_ note: Note) {
            self.note = note
            preview = LibraryMapping.storedPreview(note.previewText) ?? note.transcriptPreview.map {
                Highlighted($0.text, leadingEllipsis: $0.leadingEllipsis, trailingEllipsis: $0.trailingEllipsis)
            }
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
    }

    /// The notes outside Recently Deleted, newest first.
    public private(set) var entries: [Entry] = []
    private var cache: [UUID: Entry] = [:]

    public init(_ notes: [Note] = []) { update(notes) }

    /// Takes the notes as they are now (newest first), keeping what was worked out for the unchanged ones.
    public mutating func update(_ notes: [Note]) {
        var next: [UUID: Entry] = [:]
        next.reserveCapacity(notes.count)
        entries = notes.compactMap { note in
            guard note.trashedAt == nil else { return nil }
            let entry = cache[note.id].flatMap { $0.note == note ? $0 : nil } ?? Entry(note)
            next[note.id] = entry
            return entry
        }
        cache = next
    }

    public func entry(_ id: UUID) -> Entry? { cache[id] }

    /// The notes that match every phrase of `query`, newest first; every note when there is no query (only
    /// punctuation was typed).
    public mutating func search(_ query: SearchQuery?) -> [Hit] {
        guard let query else { return entries.map { Hit(entry: $0, snippet: "", titleSnippet: $0.note.title) } }
        var hits: [Hit] = []
        for index in entries.indices {
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
