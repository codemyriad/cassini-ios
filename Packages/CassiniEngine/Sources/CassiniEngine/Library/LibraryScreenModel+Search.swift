import Foundation
import Observation
import CassiniNotebook

/// The Library's index of the notes, kept up to date as they change, and its search, run off the main actor after
/// the debounce.
extension LibraryScreenModel {
    /// Indexes the notes now and again each time they change: the change is observed, and the index is brought up to
    /// date on the main actor right after it.
    func observeNotes() {
        pendingNotes = nil
        let notes = withObservationTracking { ports.notes() } onChange: { [weak self] in
            // The stores change on the main actor, so the update is scheduled right away and `settle()` sees it.
            if Thread.isMainThread {
                MainActor.assumeIsolated { self?.notesChanged() }
            } else {
                Task { @MainActor [weak self] in self?.notesChanged() }
            }
        }
        index.update(notes)
        guard index.revision != revision else { return }
        revision = index.revision
        if !searched.isEmpty, found?.revision != revision { search() }
    }

    func notesChanged() {
        guard pendingNotes == nil else { return }
        pendingNotes = Task { @MainActor [weak self] in self?.observeNotes() }
    }

    /// Searches the notes for `searched` off the main actor, a thousand notes being more than a frame's work; the
    /// tokens it works out are kept for the next search. A search over notes that changed meanwhile still publishes
    /// its results, then runs again over the new notes; a new query cancels it.
    func search() {
        let query = searched
        if let running {
            if running.query == query { return } // it searches again over the new notes when it answers
            running.task.cancel()
        }
        let snapshot = index, revision = index.revision
        let task = Task { [weak self] in
            let work = Task.detached(priority: .userInitiated) {
                var copy = snapshot
                return (copy.search(SearchQuery(query)), copy)
            }
            let (hits, searched) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
            guard let self, !Task.isCancelled else { return }
            index.adoptTokens(from: searched)
            found = Found(query: query, revision: revision, hits: hits)
            running = nil
            if self.searched == query, revision != index.revision { search() }
        }
        running = (query, task)
    }

    func scheduleSearch() {
        pendingSearch?.cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text != searched else { pendingSearch = nil; return }
        guard !text.isEmpty else {
            searched = ""
            found = nil
            running?.task.cancel()
            running = nil
            pendingSearch = nil
            return
        }
        pendingSearch = Task { [weak self, clock = ports.clock] in
            do { try await clock.sleep(for: Self.searchDebounce) } catch { return }
            guard let self, !Task.isCancelled else { return }
            pendingSearch = nil
            searched = text
            search()
        }
    }
}
