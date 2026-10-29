import Foundation
import Synchronization
import CassiniNotebook

/// The one owner of the draft speaker names of every running or paused note (Android's `NamesStore` and
/// `NamingGate`): `work/names.json` beside the checkpoint.
///
/// - **One value per note.** A note's names are read from `names.json` the first time they are needed and then kept in
///   memory until `release`. Every change, from the Note screen or from the job, runs a pure `DraftNames` reducer under
///   the store's lock and writes the result, so no change is lost when the two change the names at once, and the last
///   write holds the latest names.
/// - **Writes.** `names.json` is written into the note's `work/` folder, which a write makes when the note's folder is
///   there; a failed write keeps the value in memory, and the next change writes it again. A missing or unreadable file
///   reads as `DraftNames.empty`.
/// - **The gate.** The job closes naming once the words are done (`close`) and opens it at the start of every run and
///   when a run that closed it ends without putting the names into the note (`open`). A change from the screen
///   (`mutateIfOpen`) does nothing while naming is closed; the job's own changes (`mutate`) always apply.
/// - **Observers** (`changes`) get the current names first, then every new value; `release` sends `DraftNames.empty`.
public final class DraftNamesStore: Sendable {
    public static let filename = "names.json"

    private struct State {
        var open: [UUID: DraftNames] = [:]
        var closed: Set<UUID> = []
        var observers: [UUID: [UUID: AsyncStream<DraftNames>.Continuation]] = [:]
    }

    private let root: URL
    private let directory: @Sendable (UUID) -> URL
    private let state = Mutex(State())

    /// `root` holds the note folders; `directory` gives a note's `work/` folder.
    public init(root: URL, directory: @escaping @Sendable (UUID) -> URL) {
        self.root = root
        self.directory = directory
    }

    /// The draft names of `notes`' notes, beside their checkpoints (`CheckpointFiles`).
    public convenience init(notes: NoteStore) {
        let files = CheckpointFiles(notes: notes)
        self.init(root: notes.root, directory: { files.directory(for: $0) })
    }

    /// The current draft names of `noteID`.
    public func current(_ noteID: UUID) -> DraftNames {
        state.withLock { load(noteID, &$0) }
    }

    /// Applies `reducer` and writes the result; returns it. For the job, whose changes pass the gate.
    @discardableResult
    public func mutate(_ noteID: UUID, _ reducer: (DraftNames) throws -> DraftNames) rethrows -> DraftNames {
        let (result, observers) = try state.withLock { state -> (DraftNames, [AsyncStream<DraftNames>.Continuation]) in
            let before = load(noteID, &state)
            let after = try reducer(before)
            state.open[noteID] = after
            if after != before { write(after, noteID) }
            return (after, Array((state.observers[noteID] ?? [:]).values))
        }
        for observer in observers { observer.yield(result) }
        return result
    }

    /// Applies `reducer` while naming of `noteID` is open, for the Note screen. False when naming is closed and
    /// nothing changed.
    @discardableResult
    public func mutateIfOpen(_ noteID: UUID, _ reducer: (DraftNames) throws -> DraftNames) rethrows -> Bool {
        guard isOpen(noteID) else { return false }
        try mutate(noteID, reducer)
        return true
    }

    /// Applies `reducer` to every draft: the notes in memory and every `names.json` on disk (Forget, Forget everyone).
    /// Returns the notes it changed.
    @discardableResult
    public func mutateAll(_ reducer: (DraftNames) -> DraftNames) -> [UUID] {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        let onDisk = folders.compactMap(UUID.init(uuidString:)).filter {
            FileManager.default.fileExists(atPath: file(for: $0).path)
        }
        let notes = Set(onDisk).union(state.withLock { Set($0.open.keys) })
        return notes.sorted { $0.uuidString < $1.uuidString }.filter { id in
            let before = current(id)
            return mutate(id, reducer) != before
        }
    }

    public func isOpen(_ noteID: UUID) -> Bool { state.withLock { !$0.closed.contains(noteID) } }

    public func open(_ noteID: UUID) { _ = state.withLock { $0.closed.remove(noteID) } }

    /// Closes naming and returns the names as they are now: the job puts these into the note.
    public func close(_ noteID: UUID) -> DraftNames {
        state.withLock { state in
            state.closed.insert(noteID)
            return load(noteID, &state)
        }
    }

    /// Forgets the names in memory, so the next use reads `names.json` again (after the job's work is gone, or a
    /// Start over). Observers get `DraftNames.empty`.
    public func release(_ noteID: UUID) {
        let observers = state.withLock { state in
            state.open[noteID] = nil
            return Array((state.observers[noteID] ?? [:]).values)
        }
        for observer in observers { observer.yield(.empty) }
    }

    /// The names of `noteID` now and after every change.
    public func changes(_ noteID: UUID) -> AsyncStream<DraftNames> {
        let (stream, continuation) = AsyncStream<DraftNames>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let token = UUID()
        let first = state.withLock { state in
            state.observers[noteID, default: [:]][token] = continuation
            return load(noteID, &state)
        }
        continuation.yield(first)
        continuation.onTermination = { [weak self] _ in
            self?.state.withLock { _ = $0.observers[noteID]?.removeValue(forKey: token) }
        }
        return stream
    }

    // MARK: - Files

    private func file(for noteID: UUID) -> URL { directory(noteID).appendingPathComponent(Self.filename) }

    private func load(_ noteID: UUID, _ state: inout State) -> DraftNames {
        if let names = state.open[noteID] { return names }
        let names = (try? Data(contentsOf: file(for: noteID))).flatMap { try? JSONDecoder().decode(DraftNames.self, from: $0) }
            ?? .empty
        state.open[noteID] = names
        return names
    }

    /// Writes into `work/`, making it when the note's folder is there; nothing once the note is gone.
    private func write(_ names: DraftNames, _ noteID: UUID) {
        let folder = directory(noteID)
        do {
            if !FileManager.default.fileExists(atPath: folder.path) {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
            }
            try DurableFile.write(names.encoded(), to: file(for: noteID))
        } catch {
            // The value in memory stays the truth; the next change writes it again.
        }
    }
}
