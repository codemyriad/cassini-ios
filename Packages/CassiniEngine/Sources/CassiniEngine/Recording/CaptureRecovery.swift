import Foundation
import CassiniNotebook

/// Finishes the recordings a crash or a kill left open. Runs at launch, before a new recording can begin.
///
/// - `rebuild(in:)`, before the notes are read: a note directory that holds audio but whose `note.json` is missing or
///   damaged gets a new note, "Recovered recording 8 Oct", origin `recovered`. The damaged file is kept beside it as
///   `note.json.corrupt-<ms>`. A `note.json` from a newer Cassini, or one that is readable but refused, is left alone.
/// - `recover(in:activeNoteID:)`, after: every live note except the one recording now gets its capture repaired and
///   becomes plain with the duration of what was written, or unplayable when nothing can be read. A plain capture
///   whose duration is unknown is repaired the same way, without a report. Files of an unfinished finish (`capture.caf`
///   or `audio.m4a` that the note does not point at) are deleted. Nothing is ever queued.
public struct CaptureRecovery: Sendable {
    public static let corruptPrefix = NoteRepository.metadataFilename + ".corrupt-"
    /// The files a recording leaves, in the order a rebuilt note prefers them.
    static let recordingFiles = [RecordingController.captureFilename, RecordingController.compressedFilename]
    static let audioExtensions: Set<String> = ["caf", "m4a", "wav", "aif", "aiff", "mp3", "aac", "flac", "opus"]

    private let audio: any AudioProcessing
    private let repairer: any CaptureRepairing
    private let clock: any AppClock
    private let recoveredTitle: @Sendable (Date) -> String

    /// `recoveredTitle` words the title of a rebuilt note for its recording time.
    public init(audio: any AudioProcessing, repairer: any CaptureRepairing, clock: any AppClock,
                recoveredTitle: @escaping @Sendable (Date) -> String) {
        self.audio = audio; self.repairer = repairer; self.clock = clock; self.recoveredTitle = recoveredTitle
    }

    /// What a capture became.
    enum Finished: Sendable {
        case playable(AudioSummary)
        case unplayable
    }

    // MARK: Rebuild

    /// Writes a note for each directory under `repository.root` that has audio and no readable `note.json`. Returns
    /// them oldest first, for the "recording recovered" notice.
    @discardableResult
    public func rebuild(in repository: NoteRepository) async -> [RecoveredRecording] {
        let fileManager = FileManager.default
        guard let folders = try? fileManager.contentsOfDirectory(at: repository.root, includingPropertiesForKeys: nil) else { return [] }
        var rebuilt: [RecoveredRecording] = []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard let id = UUID(uuidString: folder.lastPathComponent), needsRebuild(folder),
                  let audioFile = Self.audioFile(in: folder) else { continue }
            let metadata = folder.appendingPathComponent(NoteRepository.metadataFilename)
            let now = clock.now
            if fileManager.fileExists(atPath: metadata.path) {
                let setAside = folder.appendingPathComponent(Self.corruptPrefix + String(Int64(now.timeIntervalSince1970 * 1000)))
                guard (try? fileManager.moveItem(at: metadata, to: setAside)) != nil else { continue }
            }
            let url = folder.appendingPathComponent(audioFile)
            let createdAt = (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? now
            var note = Note(id: id, title: recoveredTitle(createdAt), createdAt: createdAt, audioFilename: audioFile)
            note.origin = .recovered
            // Filesystem creation is a sorting fallback, never proof of recording position zero.
            note.meetingTime = .unknown
            let original = folder.appendingPathComponent(ImportService.documentFilename)
            let documentURL = fileManager.fileExists(atPath: original.path) ? original : url
            if let portable = PortableTranscript.read(from: documentURL) {
                let playback = folder.appendingPathComponent(ImportService.playbackFilename)
                var importedAudio = ImportedAudio(filename: documentURL.lastPathComponent, duration: portable.duration ?? 0,
                                                   state: .unplayable(.unsupportedFormat))
                let hadPlayback = fileManager.fileExists(atPath: playback.path)
                do {
                    if !hadPlayback { try await audio.decodeOpus(documentURL, to: playback) }
                    let summary = try await audio.inspect(playback)
                    importedAudio = ImportedAudio(filename: ImportService.playbackFilename,
                        originalFilename: documentURL.lastPathComponent, duration: summary.duration, waveform: summary.waveform)
                } catch {
                    if !hadPlayback { try? fileManager.removeItem(at: playback) }
                }
                note = ImportedNote.make(id: id, displayName: nil, fallbackTitle: recoveredTitle(createdAt),
                    sha256: "", importedAt: createdAt, audio: importedAudio, document: portable)
                note.sourceSha256 = nil
            } else {
                apply(await finish(url), to: &note)
            }
            do {
                try repository.save(note)
                rebuilt.append(RecoveredRecording(noteID: id, createdAt: createdAt, recoveredAt: now, duration: note.duration))
            } catch {
                continue // The files stay; the next launch tries again.
            }
        }
        return rebuilt.sorted { $0.createdAt < $1.createdAt }
    }

    /// A missing `note.json`, or one that is not a note at all. A note from a newer Cassini, or one refused for its
    /// content, is not damaged and stays as it is.
    private func needsRebuild(_ folder: URL) -> Bool {
        let metadata = folder.appendingPathComponent(NoteRepository.metadataFilename)
        guard FileManager.default.fileExists(atPath: metadata.path) else { return true }
        guard let data = try? Data(contentsOf: metadata) else { return false }
        do {
            _ = try JSONDecoder().decode(Note.self, from: data)
            return false
        } catch is DecodingError {
            return true
        } catch {
            return false
        }
    }

    /// The recording's own files first, then any other audio file a note may point at.
    static func audioFile(in folder: URL) -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { NoteRepository.isAllowedFilename($0) && audioExtensions.contains(($0 as NSString).pathExtension.lowercased()) }
        let present = Set(names)
        return recordingFiles.first(where: present.contains) ?? names.sorted().first
    }

    // MARK: Recover

    /// Repairs the live notes other than `activeNoteID`, oldest first, and returns them for the "recording
    /// recovered" notice.
    @discardableResult
    public func recover(in store: NoteStore, activeNoteID: UUID?) async -> [RecoveredRecording] {
        var recovered: [RecoveredRecording] = []
        let notes = await store.all().filter { $0.id != activeNoteID }.sorted { $0.createdAt < $1.createdAt }
        for note in notes {
            let isLive = note.audio == .live
            let lacksDuration = note.audio == .plain && note.duration <= 0 && note.audioFilename == RecordingController.captureFilename
            if isLive || lacksDuration {
                let finished = await finish(store.audioURL(for: note))
                guard let saved = try? await store.mutate(note.id, { apply(finished, to: &$0) }) else { continue }
                if isLive {
                    recovered.append(RecoveredRecording(noteID: note.id, createdAt: note.createdAt, recoveredAt: clock.now,
                                                        duration: saved.duration))
                }
            }
            removeLeftovers(of: await store.note(note.id) ?? note, in: store.directory(for: note.id))
        }
        return recovered
    }

    /// Deletes a recording's files the note does not use: a half-written M4A, or the capture after its M4A was kept.
    private func removeLeftovers(of note: Note, in folder: URL) {
        let kept = [note.audioFilename, note.originalAudioFilename].compactMap { $0 }
        for name in Self.recordingFiles where !kept.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }

    // MARK: Shared

    /// Repairs the capture at `url`, then reads it.
    func finish(_ url: URL) async -> Finished {
        try? repairer.repairCapture(at: url)
        guard let summary = try? await audio.inspect(url), summary.duration > 0 else { return .unplayable }
        return .playable(summary)
    }

    private func apply(_ finished: Finished, to note: inout Note) {
        switch finished {
        case .playable(let summary):
            note.audio = .plain
            note.duration = summary.duration
            note.waveform = summary.waveform
            if note.status == .recording { note.status = .audioOnly }
            if note.failure == .audio { note.failure = nil }
        case .unplayable:
            note.audio = .unplayable(.interrupted)
            note.status = .failed
            note.failure = .audio
        }
    }
}
