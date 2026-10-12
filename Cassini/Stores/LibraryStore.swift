import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The notes as the screens see them: a main-actor mirror of `NoteStore`. Edits show at once and are written in
/// order as `NoteEdit`s, so a note saved meanwhile by another writer keeps both changes; a failed write puts the note
/// back as stored and reports the error. A change that must stick although its write failed (`showUnsaved`) stays on
/// screen and rides along with the note's next write until one succeeds.
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
    /// Changes shown but not yet written, per note, each with a token so a write clears only what it carried.
    @ObservationIgnored private var unsaved: [UUID: Unsaved] = [:]

    private struct Unsaved {
        let token = UUID()
        let change: @Sendable (inout Note) -> Void
    }

    init(root: URL, errors: ErrorPresenter) {
        self.errors = errors
        do { noteStore = try NoteStore(root: root) } catch {
            noteStore = nil
            loadFailure = error.localizedDescription
        }
    }

    /// A library over `noteStore`, for tests.
    init(noteStore: NoteStore, errors: ErrorPresenter) {
        self.errors = errors
        self.noteStore = noteStore
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
        let carried = unsaved[id]?.token
        _ = enqueue { await self.write(edit, carrying: carried, in: noteStore) }
        return true
    }

    /// Changes the note now and waits for the write; `change` follows the rules of `update(_:_:)`. Nil when there is no
    /// such note or the write failed.
    @discardableResult
    func commit(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async -> Note? {
        guard let noteStore, let edit = applyLocally(id, change) else { return nil }
        pendingWrites[id, default: 0] += 1
        let carried = unsaved[id]?.token
        return await enqueue { await self.write(edit, carrying: carried, in: noteStore) }.value
    }

    /// Shows a change whose write failed. It stays on screen over whatever is stored, and is written with the note's
    /// next write, which then keeps it on disk; until that succeeds the next launch sees the note as stored. `change`
    /// follows the rules of `update(_:_:)`.
    func showUnsaved(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) {
        guard note(id) != nil else { return }
        let earlier = unsaved[id]?.change
        unsaved[id] = Unsaved { note in
            earlier?(&note)
            change(&note)
        }
        _ = applyLocally(id, change)
    }

    /// Applies `change` to every note, writing only the notes it changed.
    func updateAll(_ change: @escaping @Sendable (inout Note) -> Void) {
        guard let noteStore else { return }
        let edits = notes.map { edit($0, change) }.filter { !$0.changesNothing }
        guard !edits.isEmpty else { return }
        for edit in edits { place(edit.after) }
        let ids = edits.map(\.id)
        for id in ids { pendingWrites[id, default: 0] += 1 }
        let carried = ids.compactMap { id in unsaved[id].map { (id, $0.token) } }
        _ = enqueue {
            do {
                try await noteStore.applyAll(edits)
                for (id, token) in carried { self.clearUnsaved(id, token: token, written: true) }
            } catch { self.reportSaveFailure(error) }
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
        unsaved[id] = nil
    }

    /// Waits until every write asked for so far has finished.
    func settle() async { await tail?.value }

    /// Takes the stored notes now, without waiting for their changes to arrive: after work that wrote `NoteStore`
    /// directly, such as the launch's recovery. Notes with queued edits keep showing them.
    func refresh() async {
        guard let noteStore else { return }
        for note in await noteStore.all() where pendingWrites[note.id, default: 0] == 0 { place(note) }
    }

    /// Applies `change` to the mirror; nil when there is no such note.
    private func applyLocally(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) -> NoteEdit? {
        guard let note = note(id) else { return nil }
        let edit = edit(note, change)
        if !edit.changesNothing { place(edit.after) }
        return edit
    }

    /// An edit of the shown `note` that writes its unsaved change first, so the edit lands it on disk too. The mirror
    /// shows the unsaved change already, so it only makes a difference on the stored note.
    private func edit(_ note: Note, _ change: @escaping @Sendable (inout Note) -> Void) -> NoteEdit {
        guard let pending = unsaved[note.id]?.change else { return NoteEdit(note, change) }
        return NoteEdit(note) { note in
            pending(&note)
            change(&note)
        }
    }

    /// Writes one edit; runs only from the queue of writes. Returns the note as written, nil when the write failed.
    /// `carried` is the unsaved change the edit includes, cleared once it is written.
    private func write(_ edit: NoteEdit, carrying carried: UUID?, in noteStore: NoteStore) async -> Note? {
        let written: Note?
        do { written = try await noteStore.apply(edit) } catch {
            reportSaveFailure(error)
            written = nil
        }
        if let carried { clearUnsaved(edit.id, token: carried, written: written != nil) }
        await finishWrite(edit.id, in: noteStore)
        return written
    }

    /// Forgets the unsaved change once a write carried it to disk, unless a newer one was shown since.
    private func clearUnsaved(_ id: UUID, token: UUID, written: Bool) {
        if written, unsaved[id]?.token == token { unsaved[id] = nil }
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

    /// Puts the note in its place, newest first, with its unsaved change on top.
    private func place(_ note: Note) {
        var note = note
        unsaved[note.id]?.change(&note)
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            if notes[index].createdAt == note.createdAt { notes[index] = note; return }
            notes.remove(at: index)
        }
        notes.insert(note, at: notes.firstIndex { $0.createdAt < note.createdAt } ?? notes.endIndex)
    }
}
