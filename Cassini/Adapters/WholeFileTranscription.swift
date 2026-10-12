import Foundation
import CassiniEngine
import CassiniNotebook

/// A job that transcribes the whole file in one pass and then tells its speakers apart. It saves no progress on the
/// way, so a stopped job starts from the beginning when it is resumed. The queue drives it through
/// `TranscriptionJobRunning` like any other job.
struct WholeFileTranscriptionJob: TranscriptionJobRunning {
    /// What the job reads from the preferences when it starts.
    struct Options: Sendable {
        var allowSpeechDownload: Bool
        var identifySpeakers: Bool
        var allowSpeakerDownload: Bool
        /// Forget everyone advances it; an analysis from an older generation keeps no voiceprints.
        var voicesGeneration: Int
    }

    let notes: NoteStore
    let transcriber: any Transcribing
    let analyzer: any SpeakerAnalyzing
    let options: @MainActor @Sendable () -> Options
    let applySpeakers: @MainActor @Sendable (SpeakerAnalysis, UUID, Int) async throws -> Void

    func run(_ job: Job, stop: StopSignal, events: @escaping @Sendable (JobEvent) -> Void) async -> JobOutcome {
        guard let note = await notes.note(job.noteID) else { return .failed(.open) }
        let options = await options()
        let work = Task { try await perform(job, note: note, options: options, events: events) }
        let watcher = Task {
            while !Task.isCancelled {
                if stop.request != nil {
                    events(.stopping)
                    work.cancel()
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        let result = await work.result
        watcher.cancel()
        switch (result, stop.request) {
        case (.success(let outcome), _): return outcome
        case (.failure, .cancel?): return .cancelled
        case (.failure, .pause(let reason)?): return .paused(reason)
        case (.failure(TranscriptionError.needsConsent), nil): return .needsConsent(missingBytes: 0)
        case (.failure(TranscriptionError.failed(let failure)), nil): return .failed(failure)
        case (.failure, nil): return .failed(.unknown)
        }
    }

    /// The transcript first, saved as soon as it is complete; then the speakers, whose failure keeps the words.
    private func perform(_ job: Job, note: Note, options: Options,
                         events: @escaping @Sendable (JobEvent) -> Void) async throws -> JobOutcome {
        let url = notes.audioURL(for: note)
        let speakerModelsReady = await analyzer.modelStatus() == .ready
        let speakersWanted = job.kind == .speakersOnly
            || (options.identifySpeakers && (options.allowSpeakerDownload || speakerModelsReady))
        if job.kind != .speakersOnly {
            let request = TranscriptionRequest(url: url, language: job.language, allowDownload: options.allowSpeechDownload)
            let started = StartOnce()
            let result = try await transcriber.transcribe(request) { event in
                switch event {
                case .preparingModel(let fraction):
                    events(.downloading(fraction.map(Self.speechProgress)))
                case .progress(let done, let total):
                    let totalMs = Self.ms(total)
                    if started.first() { events(.started(JobStart(totalMs: totalMs, speakers: speakersWanted, prints: speakersWanted))) }
                    events(.windowDone(doneMs: Self.ms(done), totalMs: totalMs, words: []))
                case .finalized:
                    break
                }
            }
            try Task.checkCancellation()
            events(.stageChanged(.saving))
            try await save(result.segments, to: note.id)
        }
        guard speakersWanted else { return .done }
        do {
            events(.stageChanged(.speakers))
            let analysis = try await analyzer.analyze(url: url, allowDownload: options.allowSpeakerDownload) { event in
                if case .preparingModels(let fraction) = event {
                    events(.downloading(fraction.map { DownloadProgress(part: .speakers, doneBytes: Int64($0 * 1000), totalBytes: 1000, verifying: false) }))
                }
            }
            try Task.checkCancellation()
            events(.stageChanged(.saving))
            try await applySpeakers(analysis, note.id, options.voicesGeneration)
        } catch {
            // A stopped speakers-only job keeps nothing to show for it; after a saved transcript the words are done.
            if job.kind == .speakersOnly, Task.isCancelled { throw CancellationError() }
            if !Task.isCancelled { _ = try? await notes.mutate(note.id) { $0.speakerAnalysisFailure = .speakers } }
        }
        return .done
    }

    private func save(_ segments: [TranscriptSegment], to id: UUID) async throws {
        let previous = UUID(), current = UUID(), date = Date()
        guard try await notes.mutate(id, { note in
            note.saveCurrentVersion(name: "Previous transcript", id: previous, date: date)
            note.transcript = segments; note.speakers = []; note.selectedVersionID = nil
            note.saveCurrentVersion(name: "On-device transcription", id: current, date: date)
            note.failure = nil; note.speakerAnalysisFailure = nil
        }) != nil else { throw TranscriptionError.failed(.save) }
    }

    private static func ms(_ seconds: TimeInterval) -> Int64 { Int64((seconds * 1000).rounded()) }

    private static func speechProgress(_ fraction: Double) -> DownloadProgress {
        DownloadProgress(part: .speech, doneBytes: Int64(fraction * 1000), totalBytes: 1000, verifying: false)
    }
}

/// True the first time only, from any thread.
private final class StartOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var started = false

    func first() -> Bool {
        lock.withLock {
            defer { started = true }
            return !started
        }
    }
}

/// Each note's `work/` directory, `<root>/<id>/work/`. The whole-file job keeps nothing there, so no note has saved
/// progress; the queue still deletes directories that no job owns.
struct WorkDirectories: JobCheckpoints {
    static let name = "work"
    let root: URL

    func status(of noteID: UUID) async -> CheckpointStatus { .missing }

    func discard(_ noteID: UUID) async throws {
        let url = directory(noteID)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }

    func notesWithWork() async -> Set<UUID> {
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return Set(folders.compactMap(UUID.init(uuidString:)).filter { id in
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: directory(id).path, isDirectory: &isDirectory) && isDirectory.boolValue
        })
    }

    private func directory(_ noteID: UUID) -> URL {
        root.appendingPathComponent(noteID.uuidString, isDirectory: true).appendingPathComponent(Self.name, isDirectory: true)
    }
}
