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

    /// Changes the note now and writes it in the background. False when there is no such note.
    @discardableResult
    func update(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) -> Bool {
        guard let index = notes.firstIndex(where: { $0.id == id }), let noteStore else { return false }
        change(&notes[index])
        pendingWrites[id, default: 0] += 1
        Task { await write(id, in: noteStore, change) }
        return true
    }

    /// Changes the note now and waits for the write. Nil when there is no such note or the write failed.
    @discardableResult
    func commit(_ id: UUID, _ change: @escaping @Sendable (inout Note) -> Void) async -> Note? {
        guard let index = notes.firstIndex(where: { $0.id == id }), let noteStore else { return nil }
        change(&notes[index])
        pendingWrites[id, default: 0] += 1
        return await write(id, in: noteStore, change)
    }

    /// Applies `change` to every note, writing only the notes it changed.
    func updateAll(_ change: @escaping @Sendable (inout Note) -> Void) {
        guard let noteStore else { return }
        for index in notes.indices { change(&notes[index]) }
        Task {
            await serialized {
                do { try await noteStore.mutateAll(change) } catch { self.reportSaveFailure(error) }
                self.notes = await noteStore.all()
            }
        }
    }

    func insert(_ note: Note) async throws {
        guard let noteStore else { throw CocoaError(.fileWriteUnknown) }
        try await serializedThrowing { try await noteStore.save(note) }
        place(note)
    }

    /// Deletes the note's directory and the note.
    func delete(_ id: UUID) async throws {
        guard let noteStore else { throw CocoaError(.fileWriteUnknown) }
        try await serializedThrowing { try await noteStore.delete(id) }
        notes.removeAll { $0.id == id }
    }

    /// Waits until every write asked for so far has finished.
    func settle() async { await tail?.value }

    @discardableResult
    private func write(_ id: UUID, in noteStore: NoteStore, _ change: @escaping @Sendable (inout Note) -> Void) async -> Note? {
        await serialized {
            defer { self.pendingWrites[id, default: 1] -= 1 }
            do {
                let saved = try await noteStore.mutate(id, change)
                if self.pendingWrites[id] == 1, let saved { self.place(saved) }
                return saved
            } catch {
                if let stored = await noteStore.note(id) { self.place(stored) }
                self.reportSaveFailure(error)
                return nil
            }
        }
    }

    private func reportSaveFailure(_ error: any Error) {
        errors.present("Could not save changes: \(error.localizedDescription)")
    }

    /// Runs `body` after every earlier write.
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async -> T) async -> T {
        let previous = tail
        let task = Task { @MainActor in
            await previous?.value
            return await body()
        }
        tail = Task { _ = await task.value }
        return await task.value
    }

    private func serializedThrowing(_ body: @escaping @MainActor () async throws -> Void) async throws {
        let result: Result<Void, any Error> = await serialized {
            do { try await body(); return .success(()) } catch { return .failure(error) }
        }
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
