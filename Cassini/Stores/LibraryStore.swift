import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The notes as the screens see them: a main-actor mirror of `NoteStore`. Edits show at once and are written in
/// order; a failed write puts the note back as stored and reports the error.
@MainActor @Observable final class LibraryStore {
    /// Newest first.
    private(set) var notes: [Note] = []
    /// Why the library could not be opened; nil when it is open.
    private(set) var loadFailure: String?
    private(set) var unreadableCount = 0

    @ObservationIgnored let noteStore: NoteStore?
    @ObservationIgnored private let errors: ErrorPresenter
    @ObservationIgnored private var tail: Task<Void, Never>?
    @ObservationIgnored private var pendingWrites: [UUID: Int] = [:]
    /// Notes whose last write failed while more of their writes were queued.
    @ObservationIgnored private var failedWrites: Set<UUID> = []
    @ObservationIgnored private var changes: Task<Void, Never>?

    init(root: URL, errors: ErrorPresenter) {
        self.errors = errors
        do { noteStore = try NoteStore(root: root) } catch {
            noteStore = nil
            loadFailure = error.localizedDescription
        }
    }

    /// Reads every note, then follows the changes others write.
    func load() async {
        guard let noteStore else {
            errors.present("Could not open your library: \(loadFailure ?? "")")
            return
        }
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                                  ofItemAtPath: noteStore.root.path)
            let report = try await noteStore.load()
            notes = report.notes
            unreadableCount = report.unreadableCount
        } catch {
            loadFailure = error.localizedDescription
            errors.present("Could not open your library: \(error.localizedDescription)")
            return
        }
        let stream = await noteStore.changes()
        changes = Task { [weak self] in
            for await change in stream { self?.apply(change) }
        }
    }

    func note(_ id: UUID) -> Note? { notes.first { $0.id == id } }
    func audioURL(_ note: Note) -> URL? { noteStore?.audioURL(for: note) }
    func originalAudioURL(_ note: Note) -> URL? { noteStore?.originalAudioURL(for: note) }
    func directory(for id: UUID) -> URL? { noteStore?.directory(for: id) }
    var root: URL? { noteStore?.root }

    /// Changes the note now and writes the result in the background. False when there is no such note.
    ///
    /// `change` runs once, here; the store receives the changed note, so ids and dates made inside it are the ones
    /// written. The write is refused when the stored note is not the one `change` saw, which only happens after an
    /// earlier write of the note failed.
    @discardableResult
    func update(_ id: UUID, _ change: (inout Note) -> Void) -> Bool {
        guard let noteStore, let (before, after) = applyLocally(id, change) else { return false }
        guard after != before else { return true }
        pendingWrites[id, default: 0] += 1
        _ = enqueue { await self.write(before, after, in: noteStore) }
        return true
    }

    /// Changes the note now and waits for the write. Nil when there is no such note or the write failed.
    @discardableResult
    func commit(_ id: UUID, _ change: (inout Note) -> Void) async -> Note? {
        guard let noteStore, let (before, after) = applyLocally(id, change) else { return nil }
        pendingWrites[id, default: 0] += 1
        return await enqueue { await self.write(before, after, in: noteStore) }.value
    }

    /// Applies `change` to every note, writing only the notes it changed.
    func updateAll(_ change: (inout Note) -> Void) {
        guard let noteStore else { return }
        var replacements: [(expected: Note, updated: Note)] = []
        for index in notes.indices {
            let before = notes[index]
            change(&notes[index])
            if notes[index] != before { replacements.append((before, notes[index])) }
        }
        guard !replacements.isEmpty else { return }
        let ids = replacements.map(\.updated.id)
        for id in ids { pendingWrites[id, default: 0] += 1 }
        _ = enqueue {
            defer {
                for id in ids {
                    self.pendingWrites[id, default: 1] -= 1
                    if self.pendingWrites[id] == 0 { self.failedWrites.remove(id) }
                }
            }
            do { try await noteStore.replaceAll(replacements) } catch { self.reportSaveFailure(error, for: ids) }
            for id in ids where self.pendingWrites[id] == 1 {
                if let stored = await noteStore.note(id) { self.place(stored) }
            }
        }
    }

    func insert(_ note: Note) async throws {
        guard let noteStore else { throw CocoaError(.fileWriteUnknown) }
        try await enqueueThrowing { try await noteStore.save(note) }
        place(note)
    }

    /// Deletes the note's directory and the note.
    func delete(_ id: UUID) async throws {
        guard let noteStore else { throw CocoaError(.fileWriteUnknown) }
        try await enqueueThrowing { try await noteStore.delete(id) }
        notes.removeAll { $0.id == id }
    }

    /// Waits until every write asked for so far has finished.
    func settle() async { await tail?.value }

    /// The note before and after `change`, which is applied to the mirror; nil when there is no such note.
    private func applyLocally(_ id: UUID, _ change: (inout Note) -> Void) -> (before: Note, after: Note)? {
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return nil }
        let before = notes[index]
        change(&notes[index])
        let after = notes[index]
        if after.createdAt != before.createdAt { place(after) }
        return (before, after)
    }

    /// Writes one change; runs only from the queue of writes.
    private func write(_ before: Note, _ after: Note, in noteStore: NoteStore) async -> Note? {
        let id = after.id
        defer {
            pendingWrites[id, default: 1] -= 1
            if pendingWrites[id] == 0 { failedWrites.remove(id) }
        }
        do {
            let saved = try await noteStore.replace(before, with: after)
            if pendingWrites[id] == 1 { place(saved) }
            return saved
        } catch {
            if let stored = await noteStore.note(id) { place(stored) }
            reportSaveFailure(error, for: [id])
            return nil
        }
    }

    /// Reports a failed write once: the writes of the same note queued after it are refused as changed elsewhere.
    private func reportSaveFailure(_ error: any Error, for ids: [UUID]) {
        let followsAFailure = error as? NoteStoreError == .changedElsewhere && ids.allSatisfy(failedWrites.contains)
        failedWrites.formUnion(ids)
        guard !followsAFailure else { return }
        errors.present("Could not save changes: \(error.localizedDescription)")
    }

    /// Queues `body` behind every write asked for so far; the queue is joined at once, so writes keep their order.
    private func enqueue<T: Sendable>(_ body: @escaping @MainActor () async -> T) -> Task<T, Never> {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return task
    }

    private func enqueueThrowing(_ body: @escaping @MainActor () async throws -> Void) async throws {
        let result: Result<Void, any Error> = await enqueue {
            do { try await body(); return .success(()) } catch { return .failure(error) }
        }.value
        try result.get()
    }

    private func apply(_ change: NoteChange) {
        switch change {
        case .saved(let note):
            guard pendingWrites[note.id, default: 0] == 0 else { return }
            place(note)
        case .deleted(let id):
            notes.removeAll { $0.id == id }
        }
    }

    /// Puts the note in its place, newest first.
    private func place(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            if notes[index].createdAt == note.createdAt { notes[index] = note; return }
            notes.remove(at: index)
        }
        notes.insert(note, at: notes.firstIndex { $0.createdAt < note.createdAt } ?? notes.endIndex)
    }
}
