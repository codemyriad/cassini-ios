import Foundation
import Observation
import CassiniNotebook

/// Prepared transcript presentation. Rendering only reads cached results; assembly and search run off the main
/// actor. Tasks belong to their views, and a cancelled or superseded preparation never replaces newer content.
@MainActor @Observable public final class TranscriptCache {
    public struct SealedKey: Equatable, Sendable {
        public let transcript: [TranscriptSegment]
        public let speakers: [NoteSpeaker]?
        public let voices: [SavedVoice]
        public let suggestions: [SpeakerSuggestion]

        public init(_ note: Note, voices: [SavedVoice], suggestions: [SpeakerSuggestion]) {
            transcript = note.transcript; speakers = note.speakers
            self.voices = voices; self.suggestions = suggestions
        }
    }

    public struct SearchKey: Equatable, Sendable {
        public let transcript: NoteTranscript
        public let query: String
        public init(_ transcript: NoteTranscript, query: String) { self.transcript = transcript; self.query = query }
    }

    private var sealedKey: SealedKey?
    private var sealedValue = NoteTranscript.empty
    private var draftKey: DraftState?
    private var draftValue = NoteTranscript.empty
    private var searchKey: SearchKey?
    private var searchValue: [TranscriptMatch] = []
    @ObservationIgnored private var sealedRequest: SealedKey?
    @ObservationIgnored private var draftRequest: DraftState?
    @ObservationIgnored private var searchRequest: SearchKey?

    public init() {}

    public var shownSealed: NoteTranscript { sealedValue }

    /// Cached `allHeaderSpeakers` when the prepared sealed transcript matches `note`, so Name a speaker can build its
    /// speaker row without rebuilding the full transcript on the main actor.
    public func allHeaderSpeakers(for note: Note) -> [TranscriptSpeaker]? {
        guard let key = sealedKey, key.transcript == note.transcript, key.speakers == note.speakers else { return nil }
        return sealedValue.allHeaderSpeakers
    }

    /// Questions use only the matching prepared snapshot, never stale presentation content.
    public func speakerCount(sealed key: SealedKey) -> Int? {
        sealedKey == key ? sealedValue.headerSpeakers.count : nil
    }
    public func speakerCount(draft key: DraftState) -> Int? {
        draftKey == key ? draftValue.headerSpeakers.count : nil
    }

    /// Count only the content this mode actually displays. In particular, a speakers-only job has no draft:
    /// a previously prepared sealed transcript must not make an empty processing screen eligible.
    public func speakerCount(mode: NoteMode?, draft: DraftState?, sealed: SealedKey?) -> Int? {
        guard let mode else { return nil }
        if mode.showsDraft {
            guard let draft, !draft.words.isEmpty else { return nil }
            return speakerCount(draft: draft)
        }
        guard mode.showsReading, let sealed else { return nil }
        return speakerCount(sealed: sealed)
    }

    /// This cache belongs to one note screen. Keep its content (and scroll extent) while names, voices,
    /// suggestions or newly sealed words prepare. Removing the transcript still takes effect immediately.
    public func sealed(_ key: SealedKey) -> NoteTranscript {
        key.transcript.isEmpty ? .empty : sealedValue
    }

    /// Keep the last completed draft while its next snapshot prepares, so the scroll content never collapses
    /// between progress reports. Each screen owns its cache; a different note cannot inherit this value.
    public func draft(_ key: DraftState) -> NoteTranscript { draftValue }

    public func matches(_ key: SearchKey) -> [TranscriptMatch] {
        canSearch(key) ? searchValue : []
    }

    private func canSearch(_ key: SearchKey) -> Bool {
        !key.transcript.isEmpty && !key.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func prepareSealed(_ key: SealedKey) async {
        guard !Task.isCancelled else { return }
        sealedRequest = key
        guard key != sealedKey else { return }
        if key.transcript.isEmpty {
            sealedValue = .empty
            sealedKey = key
            return
        }
        let value = await Self.buildSealed(key)
        guard !Task.isCancelled, sealedRequest == key else { return }
        sealedValue = value
        sealedKey = key
    }

    public func prepareDraft(_ key: DraftState) async {
        guard !Task.isCancelled else { return }
        draftRequest = key
        guard key != draftKey else { return }
        let value = await Self.buildDraft(key)
        guard !Task.isCancelled, draftRequest == key else { return }
        draftValue = value
        draftKey = key
    }

    public func prepareMatches(_ key: SearchKey) async {
        guard !Task.isCancelled else { return }
        searchRequest = key
        guard key != searchKey else { return }
        // Clearing search must also invalidate any pending result before yielding to another task.
        guard canSearch(key) else {
            searchValue = []
            searchKey = key
            return
        }
        let value = await Self.buildMatches(key)
        guard !Task.isCancelled, searchRequest == key else { return }
        searchValue = value
        searchKey = key
    }

    @concurrent private static func buildSealed(_ key: SealedKey) async -> NoteTranscript {
        var note = Note(title: "")
        note.transcript = key.transcript; note.speakers = key.speakers
        return NoteTranscripts.sealed(note, voices: key.voices, suggestions: key.suggestions)
    }

    @concurrent private static func buildDraft(_ draft: DraftState) async -> NoteTranscript {
        NoteTranscripts.draft(draft.words, tentativeFromMs: draft.tentativeFromMs == .max ? nil : draft.tentativeFromMs,
                              labels: draft.labels, automatic: draft.automatic, suggestions: draft.suggestions,
                              colourIndices: draft.colourIndices, provenance: draft.provenance)
    }

    @concurrent private static func buildMatches(_ key: SearchKey) async -> [TranscriptMatch] {
        TranscriptSearch.matches(key.transcript.turns, query: key.query)
    }
}
