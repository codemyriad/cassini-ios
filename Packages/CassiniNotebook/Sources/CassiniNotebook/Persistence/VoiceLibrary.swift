import Foundation

/// Why the saved voices cannot be changed.
public enum VoiceProblem: Hashable, Sendable {
    /// `voices.json` was written by a newer Cassini: it stays as it is and is never written.
    case newer
    /// `voices.json` could not be parsed. It was set aside as `voices.json.corrupt-<ms>`; the list stays read-only
    /// while that copy exists, until Forget everyone starts it again.
    case damaged
    /// `voices.json` could not be read just now (an I/O error). It is read again on the next access.
    case unreadable
}

public enum VoiceLibraryError: Error, Hashable, Sendable {
    /// The saved voices cannot be changed now; nothing was written.
    case readOnly(VoiceProblem)
    /// The note's prints were written by a newer Cassini and are kept as they are.
    case newerPrints(UUID)
}

/// The private voice files: `PrivateVoices/voices.json` (the saved voices) and `PrivateVoices/<note id>.json` (each
/// note's prints). They live apart from the notes, are excluded from backups, and never go into an export.
///
/// A file this Cassini cannot use is never deleted: a newer one is left alone, an unparseable one is renamed
/// `<name>.corrupt-<epoch ms>`. Not thread-safe: `VoiceStore` serialises access.
public final class VoiceLibrary {
    /// A print needs this much isolated speech to be remembered or matched (iOS threshold; Android uses 4 s).
    public static let minimumRememberSeconds: Double = 6

    public let folder: URL
    private let now: () -> Date
    public private(set) var voices: [SavedVoice] = []
    public private(set) var problem: VoiceProblem?

    /// Opens `<root>/PrivateVoices`, creating it when needed, and reads the saved voices.
    public init(root: URL, now: @escaping () -> Date = Date.init) throws {
        folder = root.appendingPathComponent("PrivateVoices", isDirectory: true)
        self.now = now
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resource = folder
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try resource.setResourceValues(values)
        read()
    }

    private var voicesFile: URL { folder.appendingPathComponent("voices.json") }
    private func printsFile(_ noteID: UUID) -> URL { folder.appendingPathComponent(NoteVoiceCodec.fileName(noteID)) }

    /// Whether the saved voices cannot be changed now.
    public var isReadOnly: Bool { refreshed(); return problem != nil }

    /// Forget everyone also starts a damaged list again; a newer or unreadable one stays untouched.
    public var canForgetEveryone: Bool { refreshed(); return problem == nil || problem == .damaged }

    /// Reads `voices.json` again when the last read failed for a passing reason.
    public func refreshed() { if problem == .unreadable { read() } }

    /// Writes the saved voices, unless they cannot be changed now.
    public func save(_ values: [SavedVoice]) throws {
        refreshed()
        if let problem { throw VoiceLibraryError.readOnly(problem) }
        try VoiceCodec.encode(values).write(to: voicesFile, options: .atomic)
        voices = values
    }

    /// The prints of every analysis of the note. A newer file reads as none and is kept; an unparseable one is set
    /// aside.
    public func prints(noteID: UUID) throws -> [SpeakerPrint] {
        let url = printsFile(noteID)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            return try NoteVoiceCodec.decode(Data(contentsOf: url))
        } catch let error as UnsupportedVoiceFileVersion where error.newer {
            return []
        } catch is DecodingError, is UnsupportedVoiceFileVersion {
            try setAside(url)
            return []
        }
    }

    public func savePrints(_ prints: [SpeakerPrint], noteID: UUID) throws {
        let url = printsFile(noteID)
        if isNewer(url) { throw VoiceLibraryError.newerPrints(noteID) }
        try NoteVoiceCodec.encode(prints).write(to: url, options: .atomic)
    }

    /// Whether any note has prints on disk.
    public var hasEvidence: Bool { !noteFiles().isEmpty }

    /// Forgets every saved voice and every print, and the copies of damaged files. Refused while `voices.json` is newer
    /// or unreadable.
    public func forgetAll() throws {
        refreshed()
        if let problem, problem != .damaged { throw VoiceLibraryError.readOnly(problem) }
        let fileManager = FileManager.default
        for url in try fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        where url.lastPathComponent.hasPrefix("voices.json") || noteID(of: url) != nil {
            try fileManager.removeItem(at: url)
        }
        voices = []
        problem = nil
    }

    /// Removes the note's prints and its samples from every saved voice, before the note is deleted for good. A voice
    /// left without samples is forgotten; those voices are returned so the notes can drop their links. Refused while
    /// `voices.json` is newer or unreadable, since it may hold samples of the note; a damaged list has none.
    @discardableResult public func removeEvidence(noteID: UUID) throws -> [UUID] {
        refreshed()
        if let problem, problem != .damaged { throw VoiceLibraryError.readOnly(problem) }
        var copy: [SavedVoice] = []
        var forgotten: [UUID] = []
        for var voice in voices {
            let before = voice.samples.count
            voice.samples.removeAll { $0.noteID == noteID }
            if voice.samples.isEmpty && before > 0 { forgotten.append(voice.id) } else { copy.append(voice) }
        }
        if copy != voices { try save(copy) }
        for url in noteFiles() where self.noteID(of: url) == noteID { try FileManager.default.removeItem(at: url) }
        return forgotten
    }

    /// Deletes the print files of notes that are gone: not in `notes`, and with no folder at `<root>/<id>`. A note
    /// folder whose `note.json` could not be read is kept with its prints, as on Android. Returns the notes swept.
    @discardableResult public func sweepOrphans(keeping notes: Set<UUID>) throws -> [UUID] {
        let root = folder.deletingLastPathComponent()
        var deleted: Set<UUID> = []
        for url in noteFiles() {
            guard let id = noteID(of: url), !notes.contains(id),
                  !FileManager.default.fileExists(atPath: root.appendingPathComponent(id.uuidString, isDirectory: true).path)
            else { continue }
            try FileManager.default.removeItem(at: url)
            deleted.insert(id)
        }
        return deleted.sorted { $0.uuidString < $1.uuidString }
    }

    // MARK: - Files

    private func read() {
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: voicesFile.path) else {
            voices = []
            problem = hasDamagedCopy ? .damaged : nil
            return
        }
        let data: Data
        do {
            data = try Data(contentsOf: voicesFile)
        } catch {
            problem = .unreadable
            return
        }
        do {
            voices = try VoiceCodec.decode(data)
            problem = hasDamagedCopy ? .damaged : nil
        } catch let error as UnsupportedVoiceFileVersion where error.newer {
            voices = []
            problem = .newer
        } catch {
            voices = []
            problem = (try? setAside(voicesFile)) == nil ? .unreadable : .damaged
        }
    }

    private var hasDamagedCopy: Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).contains { $0.hasPrefix("voices.json.corrupt-") }
    }

    /// Renames an unparseable file to `<name>.corrupt-<epoch ms>`.
    private func setAside(_ url: URL) throws {
        let stamp = Int64((now().timeIntervalSince1970 * 1000).rounded())
        try FileManager.default.moveItem(at: url, to: url.deletingLastPathComponent()
            .appendingPathComponent(url.lastPathComponent + ".corrupt-\(stamp)"))
    }

    /// The print files of notes, with the copies set aside.
    private func noteFiles() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { noteID(of: $0) != nil }
    }

    /// Whether the file at `url` holds prints of a newer Cassini.
    private func isNewer(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url) else { return false }
        do {
            _ = try NoteVoiceCodec.decode(data)
            return false
        } catch let error as UnsupportedVoiceFileVersion {
            return error.newer
        } catch {
            return false
        }
    }

    /// The note of a print file or of its set-aside copy.
    private func noteID(of url: URL) -> UUID? {
        let name = url.lastPathComponent
        let base = name.range(of: ".json.corrupt-").map { String(name[..<$0.lowerBound]) + ".json" } ?? name
        return NoteVoiceCodec.noteID(fileName: base)
    }
}
