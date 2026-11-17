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

    @Test func questionCountIncludesChipOnlySpeakersAndRejectsStaleSnapshots() async {
        let cache = TranscriptCache()
        var note = note()
        // A brief reply becomes an inline chip rather than its own paragraph header.
        note.transcript.append(.init(text: "Yes", start: 2, end: 2.5, speakerID: "b"))
        note.transcript.append(.init(text: "Let us continue", start: 2.5, end: 6, speakerID: "a"))
        note.speakers?.append(.init(id: "b", name: "Bea", colourIndex: 1))
        note.speakers?.append(.init(id: "unused", name: "No speech", colourIndex: 2))
        let key = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        #expect(cache.speakerCount(sealed: key) == nil)
        await cache.prepareSealed(key)
        #expect(cache.speakerCount(sealed: key) == 2)
        note.transcript = []
        let empty = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        #expect(cache.speakerCount(sealed: empty) == nil)
        await cache.prepareSealed(empty)
        #expect(cache.speakerCount(sealed: empty) == 0)
        #expect(cache.speakerCount(sealed: key) == nil)
    }

    @Test func draftQuestionCountWaitsForTheMatchingPreparedSnapshot() async {
        let cache = TranscriptCache()
        let draft = DraftState(words: [.init(speaker: "a", startMs: 0, endMs: 500, text: "Hello"),
                                       .init(speaker: "b", startMs: 500, endMs: 1_000, text: "Yes")],
                               tentativeFromMs: 1_000, namingOpen: true)
        #expect(cache.speakerCount(draft: draft) == nil)
        await cache.prepareDraft(draft)
        #expect(cache.speakerCount(draft: draft) == 2)
        var changed = draft
        changed.words.removeLast()
        #expect(cache.speakerCount(draft: changed) == nil)
        await cache.prepareDraft(changed)
        #expect(cache.speakerCount(draft: changed) == 1)
    }

    @Test func questionCountNeverFallsBackFromAnAbsentDraftOrHiddenTranscript() async {
        let cache = TranscriptCache()
        var note = note()
        note.transcript.append(.init(text: "Yes", start: 2, end: 3, speakerID: "b"))
        let key = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        await cache.prepareSealed(key)
        #expect(cache.speakerCount(sealed: key) == 2)
        let empty = DraftState(words: [], tentativeFromMs: 0)
        await cache.prepareDraft(empty)
        let hidden: [NoteMode?] = [nil, .processing, .paused(doneMs: 0, totalMs: 3_000, hasCheckpoint: false),
            .queued(ahead: 0, overDocument: false), .failed(overDocument: false), .audioOnly, .unplayable]
        for mode in hidden {
            #expect(cache.speakerCount(mode: mode, draft: nil, sealed: key) == nil)
            #expect(cache.speakerCount(mode: mode, draft: empty, sealed: key) == nil)
        }
        for mode in [NoteMode.reading, .queued(ahead: 0, overDocument: true), .failed(overDocument: true)] {
            #expect(cache.speakerCount(mode: mode, draft: empty, sealed: key) == 2)
        }
        let draft = DraftState(words: [.init(speaker: "a", startMs: 0, endMs: 500, text: "New words")],
                               tentativeFromMs: 500)
        #expect(cache.speakerCount(mode: .processing, draft: draft, sealed: key) == nil)
        await cache.prepareDraft(draft)
        #expect(cache.speakerCount(mode: .processing, draft: draft, sealed: key) == 1)
        #expect(cache.speakerCount(mode: .reading, draft: draft, sealed: key) == 2)
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
        let previous = cache.sealed(key)
        #expect(cache.sealed(renamed) == previous, "Keep content and scroll extent while the rename prepares")
        await cache.prepareSealed(renamed)
        #expect(cache.sealed(renamed) == NoteTranscripts.sealed(note))
        #expect(cache.sealed(key) == NoteTranscripts.sealed(note), "Always expose the latest completed build")
        let renamedSearch = TranscriptCache.SearchKey(cache.sealed(renamed), query: "there")
        #expect(cache.matches(renamedSearch) == cache.matches(search))
        await cache.prepareMatches(renamedSearch)
        #expect(cache.matches(renamedSearch) == TranscriptSearch.matches(cache.sealed(renamed).turns, query: "there"))
    }

    @Test func sealedContentSurvivesReplacementAndCancellationButClearsOnRemoval() async {
        let cache = TranscriptCache()
        var note = note()
        let original = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        await cache.prepareSealed(original)
        let previous = cache.sealed(original)
        note.transcript.append(.init(text: "Newly sealed words", start: 2, end: 4, speakerID: "a"))
        let appended = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        let cancelled = Task { await cache.prepareSealed(appended) }
        #expect(cache.sealed(appended) == previous)
        cancelled.cancel()
        await cancelled.value
        #expect(cache.sealed(appended) == previous)
        await cache.prepareSealed(appended)
        #expect(cache.sealed(appended) == NoteTranscripts.sealed(note))

        note.transcript = []
        let removed = TranscriptCache.SealedKey(note, voices: [], suggestions: [])
        #expect(cache.sealed(removed) == .empty, "A removed transcript must disappear before preparation")
        await cache.prepareSealed(removed)
        #expect(cache.shownSealed == .empty)
        #expect(cache.sealed(original) == .empty, "No resurrected content while a replacement starts")
        await cache.prepareSealed(original)
        #expect(cache.sealed(original) == previous)
    }

    @Test func matchesStayVisibleUntilTheNextNonblankQueryCompletes() async {
        let cache = TranscriptCache()
        let transcript = NoteTranscripts.sealed(note())
        let original = TranscriptCache.SearchKey(transcript, query: "there")
        #expect(cache.matches(original).isEmpty)
        await cache.prepareMatches(original)
        let previous = cache.matches(original)
        #expect(!previous.isEmpty)
        let edited = TranscriptCache.SearchKey(transcript, query: "Hello")
        #expect(cache.matches(edited) == previous)
        await cache.prepareMatches(edited)
        #expect(cache.matches(edited) == TranscriptSearch.matches(transcript.turns, query: "Hello"))
        #expect(cache.matches(edited) != previous)

        let noHits = TranscriptCache.SearchKey(transcript, query: "absent")
        #expect(!cache.matches(noHits).isEmpty, "Retain hits until a nonblank search finishes, even with no new hits")
        await cache.prepareMatches(noHits)
        #expect(cache.matches(noHits).isEmpty)

        for query in ["", " \n\t"] {
            await cache.prepareMatches(original)
            let cleared = TranscriptCache.SearchKey(transcript, query: query)
            #expect(cache.matches(cleared).isEmpty, "Clearing search hides highlights immediately")
            await cache.prepareMatches(cleared)
            #expect(cache.matches(edited).isEmpty, "Cleared highlights cannot return while typing a new query")
        }
        await cache.prepareMatches(original)
        let removed = TranscriptCache.SearchKey(.empty, query: "there")
        #expect(cache.matches(removed).isEmpty)
        await cache.prepareMatches(removed)
        #expect(cache.matches(original).isEmpty)
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
