import CassiniCore

/// The input of every export writer (features.md section 9).
///
/// `words` are the exported variant's words in canonical order; the writers never re-sort them. `labels` maps a
/// speaker id to its display label. A speaker without a label is shown by its id.
///
/// TXT, SRT and VTT exports are word-body derivatives without integrity data; only the sealed `.opus` is a portable
/// Cassini artifact.
public struct ExportTranscript: Hashable, Sendable {
    public var title: String
    public var durationMs: Int64
    public var words: [Word]
    public var labels: [String: String]

    public init(title: String, durationMs: Int64, words: [Word], labels: [String: String]) {
        self.title = title; self.durationMs = durationMs; self.words = words; self.labels = labels
    }

    /// The number of distinct speakers that say at least one word.
    public var speakerCount: Int { Set(words.lazy.map(\.speaker)).count }

    /// The display label of `speaker`, or the id itself when `labels` has none.
    public func label(_ speaker: String) -> String { labels[speaker] ?? speaker }
}
