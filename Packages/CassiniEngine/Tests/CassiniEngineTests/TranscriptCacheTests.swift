import Testing
import CassiniEngine
import CassiniNotebook

@MainActor struct TranscriptCacheTests {
    private func note() -> Note {
        var note = Note(title: "Meeting")
        note.transcript = [.init(text: "Hello there", start: 0, end: 2, speakerID: "a")]
        note.speakers = [.init(id: "a", name: "Ada", colourIndex: 0)]
        return note
    }

    @Test func preparationMatchesThePureRendererAndRefreshesNamesAndSearch() async {
        let cache = TranscriptCache()
        var note = note()
        let key = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        #expect(cache.sealed(key) == .empty)
        await cache.prepareSealed(key)
        #expect(cache.sealed(key) == NoteTranscripts.sealed(note))
        let search = TranscriptCache.SearchKey(cache.sealed(key), query: "there")
        await cache.prepareMatches(search)
        #expect(cache.matches(search) == TranscriptSearch.matches(cache.sealed(key).turns, query: "there"))
        #expect(!cache.matches(search).isEmpty)

        note.speakers?[0].name = "Grace"
        let renamed = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        #expect(renamed != key)
        #expect(cache.sealed(renamed) == .empty, "Do not present an old name for a new input")
        await cache.prepareSealed(renamed)
        #expect(cache.sealed(renamed) == NoteTranscripts.sealed(note))
        #expect(cache.sealed(key) == .empty)
    }

    @Test func cancelledPreparationNeverPublishes() async {
        let cache = TranscriptCache()
        let note = note()
        let key = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        // Cancel while the MainActor is still held: the task has not started, so this is deterministic.
        let task = Task { await cache.prepareSealed(key) }
        task.cancel()
        await task.value
        #expect(cache.shownSealed == .empty)
        await cache.prepareSealed(key)
        #expect(cache.shownSealed == NoteTranscripts.sealed(note))
    }

    @Test func draftsKeepTheirLastPreparedContentUntilTheNextSnapshotIsReady() async {
        let cache = TranscriptCache()
        let draft = DraftState(words: [.init(speaker: "a", startMs: 0, endMs: 100, text: "Hello")],
                               tentativeFromMs: 50, labels: ["a": "Ada"])
        await cache.prepareDraft(draft)
        let expected = NoteTranscripts.draft(draft.words, tentativeFromMs: 50, labels: draft.labels)
        #expect(cache.draft(draft) == expected)
        var next = draft
        next.labels["a"] = "Grace"
        #expect(cache.draft(next) == expected, "No empty frame between progress updates")
        await cache.prepareDraft(next)
        #expect(cache.draft(next) == NoteTranscripts.draft(next.words, tentativeFromMs: 50, labels: next.labels))
    }

    @Test func presentationKeyIncludesTimingProvenanceAndColourButNotPlaybackPosition() {
        var note = note()
        let key = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        note.playbackPosition = 1
        #expect(TranscriptCache.SealedKey(note, voices: [], suggestions: []) == key)
        note.transcript[0].wordEndsBoundedByAudio = true
        #expect(TranscriptCache.SealedKey(note, voices: [], suggestions: []) != key)
        let bounded = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        note.speakers?[0].colourIndex = 2
        #expect(TranscriptCache.SealedKey(note, voices: [], suggestions: []) != bounded)
    }
}
