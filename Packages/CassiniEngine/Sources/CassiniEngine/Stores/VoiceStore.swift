import Foundation
import CassiniNotebook

/// The saved voices as one read gives them, with whether they can be changed.
public struct VoiceSnapshot: Hashable, Sendable {
    public var voices: [SavedVoice]
    public var problem: VoiceProblem?
    /// Whether any note has voiceprints on disk.
    public var hasEvidence: Bool
    public var canForgetEveryone: Bool

    public var isReadOnly: Bool { problem != nil }

    public init(voices: [SavedVoice] = [], problem: VoiceProblem? = nil, hasEvidence: Bool = false,
                canForgetEveryone: Bool = true) {
        self.voices = voices; self.problem = problem; self.hasEvidence = hasEvidence
        self.canForgetEveryone = canForgetEveryone
    }
}

/// The result of an edit of the saved voices.
public enum VoiceEdit: Hashable, Sendable {
    case done
    case notFound
    /// The saved voices cannot be changed now; nothing was changed.
    case readOnly
    /// The name is blank or longer than `Limits.nameMaxLength` after trimming.
    case invalid
    /// A voice file could not be written (full disk, I/O error); try again.
    case failed(String)
}

/// The saved voices and each note's voiceprints, read and written off the main actor, one change at a time.
public actor VoiceStore {
    private let library: VoiceLibrary

    /// Opens `<root>/PrivateVoices`, creating it when needed.
    public init(root: URL, now: @escaping @Sendable () -> Date = Date.init) throws {
        library = try VoiceLibrary(root: root, now: now)
    }

    public func snapshot() -> VoiceSnapshot {
        library.refreshed()
        return VoiceSnapshot(voices: library.voices, problem: library.problem, hasEvidence: library.hasEvidence,
                             canForgetEveryone: library.canForgetEveryone)
    }

    public func voices() -> [SavedVoice] { library.voices }

    /// Writes the saved voices; throws `VoiceLibraryError.readOnly` when they cannot be changed now.
    public func save(_ voices: [SavedVoice]) throws { try library.save(voices) }

    /// Applies `change` to the saved voices and writes them, unless it left them as they were.
    @discardableResult
    public func mutate(_ change: @Sendable (inout [SavedVoice]) -> Void) throws -> [SavedVoice] {
        library.refreshed()
        var voices = library.voices
        change(&voices)
        if voices != library.voices { try library.save(voices) }
        return voices
    }

    /// Renames a saved voice. Names already in notes stay as they are.
    public func rename(_ id: UUID, name: String) -> VoiceEdit {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= Limits.nameMaxLength else { return .invalid }
        return edit(id) { $0.name = trimmed }
    }

    /// Forgets one saved voice. The caller drops the notes' links to it first, so a failed write can be retried.
    public func forget(_ id: UUID) -> VoiceEdit {
        edit(id, remove: true) { _ in }
    }

    /// Forgets every saved voice and every print. The caller advances the voices generation first, so an analysis
    /// that started before keeps nothing.
    public func forgetEveryone() -> VoiceEdit {
        guard library.canForgetEveryone else { return .readOnly }
        do {
            try library.forgetAll()
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    public func prints(noteID: UUID) throws -> [SpeakerPrint] { try library.prints(noteID: noteID) }

    public func savePrints(_ prints: [SpeakerPrint], noteID: UUID) throws { try library.savePrints(prints, noteID: noteID) }

    /// Adds the prints of another analysis of the note.
    public func appendPrints(_ prints: [SpeakerPrint], noteID: UUID) throws {
        guard !prints.isEmpty else { return }
        try library.savePrints(library.prints(noteID: noteID) + prints, noteID: noteID)
    }

    /// Whether any note has voiceprints on disk.
    public func hasEvidence() -> Bool { library.hasEvidence }

    /// Removes the note's voiceprints and its samples from every saved voice.
    public func removeEvidence(noteID: UUID) throws { try library.removeEvidence(noteID: noteID) }

    /// Forgets every saved voice and every voiceprint.
    public func forgetAll() throws { try library.forgetAll() }

    /// Deletes the voiceprints of notes not in `notes`, at launch. Returns those notes.
    @discardableResult public func sweepOrphans(keeping notes: Set<UUID>) throws -> [UUID] {
        try library.sweepOrphans(keeping: notes)
    }

    private func edit(_ id: UUID, remove: Bool = false, _ change: (inout SavedVoice) -> Void) -> VoiceEdit {
        if library.isReadOnly { return .readOnly }
        var voices = library.voices
        guard let index = voices.firstIndex(where: { $0.id == id }) else { return .notFound }
        if remove { voices.remove(at: index) } else { change(&voices[index]) }
        do {
            try library.save(voices)
            return .done
        } catch {
            return .failed(error.localizedDescription)
        }
    }
}
