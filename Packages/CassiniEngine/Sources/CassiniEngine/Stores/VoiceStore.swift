import Foundation
import CassiniNotebook

/// The saved voices and each note's voiceprints, read and written off the main actor, one change at a time.
public actor VoiceStore {
    private let library: VoiceLibrary

    /// Opens `<root>/PrivateVoices`, creating it when needed.
    public init(root: URL) throws {
        library = try VoiceLibrary(root: root)
    }

    public func voices() -> [SavedVoice] { library.voices }

    public func save(_ voices: [SavedVoice]) throws { try library.save(voices) }

    /// Applies `change` to the saved voices and writes them, unless it left them as they were.
    @discardableResult
    public func mutate(_ change: @Sendable (inout [SavedVoice]) -> Void) throws -> [SavedVoice] {
        var voices = library.voices
        change(&voices)
        if voices != library.voices { try library.save(voices) }
        return voices
    }

    public func prints(noteID: UUID) throws -> [SpeakerPrint] { try library.prints(noteID: noteID) }

    public func savePrints(_ prints: [SpeakerPrint], noteID: UUID) throws { try library.savePrints(prints, noteID: noteID) }

    /// Whether any note has voiceprints on disk.
    public func hasEvidence() -> Bool { library.hasEvidence }

    /// Removes the note's voiceprints and its samples from every saved voice.
    public func removeEvidence(noteID: UUID) throws { try library.removeEvidence(noteID: noteID) }

    /// Forgets every saved voice and every voiceprint.
    public func forgetAll() throws { try library.forgetAll() }
}
