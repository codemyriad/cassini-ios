import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The notes as the screens see them: a main-actor mirror of `NoteStore`. Edits show at once and are written in
/// order as `NoteEdit`s, so a note saved meanwhile by another writer keeps both changes; a failed write puts the note
/// back as stored and reports the error.
@MainActor @Observable final class LibraryStore {
    /// Newest first.
    private(set) var notes: [Note] = []
    /// Why the library could not be opened; nil when it is open.
    private(set) var loadFailure: String?
    private(set) var unreadableCount = 0

    @ObservationIgnored let noteStore: NoteStore?
    @ObservationIgnored private let errors: ErrorPresenter
    @ObservationIgnored private var tail: Task<Void, Never>?
    /// Queued edits per note; while a note has any, the mirror shows them rather than what others save.
    @ObservationIgnored private var pendingWrites: [UUID: Int] = [:]
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

    /// Changes the note now and writes the change in the background. False when there is no such note.
    ///
    /// `change` may run again on the stored note when another writer saved it in between, so it must only set the
    /// fields it owns, never assign the whole note, and ids and dates it stamps on the note should be made before it.
    @discardableResult
    func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) -> Bool {
        guard let noteStore, let edit = applyLocally(id, change) else { return false }
        guard !edit.changesNothing else { return true }
        pendingWrites[id, default: 0] += 1
        _ = enqueue { await self.write(edit, in: noteStore) }
        return true
    }

    /// Changes the note now and waits for the write; `change` follows the rules of `update(_:_:)`. Nil when there is no
    /// such note or the write failed.
    @discardableResult
    func commit(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async -> Note? {
        guard let noteStore, let edit = applyLocally(id, change) else { return nil }
        pendingWrites[id, default: 0] += 1
        return await enqueue { await self.write(edit, in: noteStore) }.value
    }

    /// Changes the note on screen only: a change that could not be written. It lasts until the note is saved again or
    /// the app relaunches.
    func showUnsaved(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) { _ = applyLocally(id, change) }

    /// Applies `change` to every note, writing only the notes it changed.
    func updateAll(_ change: @escaping @Sendable (inout Note) -> Void) {
        guard let noteStore else { return }
        let edits = notes.map { NoteEdit($0, change) }.filter { !$0.changesNothing }
        guard !edits.isEmpty else { return }
        for edit in edits { place(edit.after) }
        let ids = edits.map(\.id)
        for id in ids { pendingWrites[id, default: 0] += 1 }
        _ = enqueue {
            do { try await noteStore.applyAll(edits) } catch { self.reportSaveFailure(error) }
            for id in ids { await self.finishWrite(id, in: noteStore) }
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

    /// Applies `change` to the mirror; nil when there is no such note.
    private func applyLocally(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) -> NoteEdit? {
        guard let note = note(id) else { return nil }
        let edit = NoteEdit(note, change)
        if !edit.changesNothing { place(edit.after) }
        return edit
    }

    /// Writes one edit; runs only from the queue of writes. Returns the note as written, nil when the write failed.
    private func write(_ edit: NoteEdit, in noteStore: NoteStore) async -> Note? {
        let written: Note?
        do { written = try await noteStore.apply(edit) } catch {
            reportSaveFailure(error)
            written = nil
        }
        await finishWrite(edit.id, in: noteStore)
        return written
    }

    /// Counts a queued write of the note as done. After the last one, the mirror takes the note as stored: with
    /// every queued edit, and with what others saved while the edits were queued, which `apply(_:)` skipped.
    private func finishWrite(_ id: UUID, in noteStore: NoteStore) async {
        if pendingWrites[id] == 1, let stored = await noteStore.note(id), pendingWrites[id] == 1 { place(stored) }
        pendingWrites[id, default: 1] -= 1
        if pendingWrites[id] == 0 { pendingWrites[id] = nil }
    }

    private func reportSaveFailure(_ error: any Error) {
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
