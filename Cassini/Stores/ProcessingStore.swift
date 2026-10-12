import Foundation
import Observation
import CassiniEngine
import CassiniNotebook

/// The transcription queue: one job at a time, in order, each a transcript and then, when wanted, the speakers.
/// The queue lives in memory; a relaunch makes interrupted notes ready to transcribe again.
@MainActor @Observable final class ProcessingStore {
    private(set) var state = ProcessingState()

    @ObservationIgnored private let transcriber: any Transcribing
    @ObservationIgnored private let analyzer: any SpeakerAnalyzing
    @ObservationIgnored private let background: any BackgroundRunner
    @ObservationIgnored private let library: LibraryStore
    @ObservationIgnored private let voices: VoicesStore
    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let notices: NoticesStore
    @ObservationIgnored private var speakersOnly: Set<UUID> = []
    /// Notes whose audio is still being written; they cannot be queued yet.
    @ObservationIgnored private var finalizing: Set<UUID> = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var backgroundToken: BackgroundToken?

    init(transcriber: any Transcribing, analyzer: any SpeakerAnalyzing, background: any BackgroundRunner,
         library: LibraryStore, voices: VoicesStore, settings: SettingsStore, notices: NoticesStore) {
        self.transcriber = transcriber; self.analyzer = analyzer; self.background = background
        self.library = library; self.voices = voices; self.settings = settings; self.notices = notices
    }

    func speakerModelsReady() async -> Bool { await analyzer.modelStatus() == .ready }

    func beginFinalizing(_ id: UUID) { finalizing.insert(id) }
    func endFinalizing(_ id: UUID) { finalizing.remove(id) }

    func enqueue(_ id: UUID, speakersOnly onlySpeakers: Bool = false) {
        guard let note = library.note(id), note.trashedAt == nil, !note.isRecording, note.audio.isPlayable,
              !state.isRunning(id), !finalizing.contains(id), !state.isQueued(id), library.audioURL(note) != nil else { return }
        let language = settings.speechLanguage
        guard library.update(id, { $0.status = .queued; $0.failure = nil; $0.language = language }) else { return }
        if onlySpeakers { speakersOnly.insert(id) }
        state.queue.append(id)
        processNext()
    }

    /// Takes the note out of the queue or stops its job; its earlier transcript stays.
    func cancel(_ id: UUID, failure: JobFailure? = nil) {
        state.queue.removeAll { $0 == id }
        speakersOnly.remove(id)
        if state.isRunning(id) { task?.cancel() }
        library.update(id) { $0.status = $0.transcript.isEmpty ? .audioOnly : .ready; $0.failure = failure }
    }

    /// At launch: jobs that were queued or running when Cassini closed are not resumed; their notes can be
    /// transcribed again.
    func reconcileOnStart() {
        for note in library.notes where note.status == .transcribing || note.status == .queued {
            library.update(note.id) { $0.status = $0.transcript.isEmpty ? .audioOnly : .ready; $0.failure = .interrupted }
        }
    }

    private func processNext() {
        guard task == nil, !state.queue.isEmpty else { return }
        let id = state.queue.removeFirst()
        guard let note = library.note(id), let url = library.audioURL(note), note.trashedAt == nil,
              library.update(id, { $0.status = .transcribing }) else { processNext(); return }
        state.running = RunningJob(noteID: id, title: note.title)
        let onlySpeakers = speakersOnly.remove(id) != nil
        let request = TranscriptionRequest(url: url, language: note.language, allowDownload: settings.downloadsAllowed)
        let generation = settings.voicesGeneration
        backgroundToken = background.begin(title: "Finish transcription", progress: Progress()) { [weak self] in
            self?.suspendAll()
        }
        task = Task { [weak self] in
            await self?.run(id, request: request, onlySpeakers: onlySpeakers, generation: generation)
            self?.finishRun()
        }
    }

    private func run(_ id: UUID, request: TranscriptionRequest, onlySpeakers: Bool, generation: Int) async {
        do {
            if !onlySpeakers { try await transcribe(id, request) }
            if try await shouldAnalyzeSpeakers(onlySpeakers) {
                try await analyzeSpeakers(id, url: request.url, generation: generation)
            }
            try Task.checkCancellation()
            library.update(id) { $0.status = .ready; $0.failure = nil }
        } catch is CancellationError {
            // The note was already set back by whoever cancelled.
        } catch TranscriptionError.needsConsent {
            cancel(id)
            notices.post("A speech model is needed. Allow model downloads in Settings, then try again. Audio stays on this device.")
        } catch {
            guard !Task.isCancelled else { return }
            let failure = if case TranscriptionError.failed(let code) = error { code } else { JobFailure.unknown }
            library.update(id) { $0.status = .failed; $0.failure = failure }
        }
    }

    private func transcribe(_ id: UUID, _ request: TranscriptionRequest) async throws {
        let result = try await transcriber.transcribe(request) { [weak self] event in
            Task { @MainActor in self?.report(event, for: id) }
        }
        try Task.checkCancellation()
        let saved = await library.commit(id) { note in
            note.saveCurrentVersion(name: "Previous transcript")
            note.transcript = result.segments; note.speakers = []; note.selectedVersionID = nil
            note.saveCurrentVersion(name: "On-device transcription")
            note.failure = nil
        }
        guard saved != nil else { throw TranscriptionError.failed(.save) }
    }

    private func shouldAnalyzeSpeakers(_ onlySpeakers: Bool) async throws -> Bool {
        if onlySpeakers { return true }
        guard settings.identifySpeakers else { return false }
        if settings.speakerDownloadsAllowed { return true }
        return await speakerModelsReady()
    }

    private func analyzeSpeakers(_ id: UUID, url: URL, generation: Int) async throws {
        do {
            let analysis = try await analyzer.analyze(url: url, allowDownload: settings.speakerDownloadsAllowed) { [weak self] event in
                Task { @MainActor in self?.report(event, for: id) }
            }
            try Task.checkCancellation()
            try await voices.applySpeakerAnalysis(analysis, to: id, generation: generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            library.update(id) { $0.speakerAnalysisFailure = .speakers }
        }
    }

    private func report(_ event: TranscriptionEvent, for id: UUID) {
        guard state.isRunning(id) else { return }
        switch event {
        case .preparingModel(let fraction):
            state.running?.phase = .downloading(fraction); state.running?.fraction = fraction
        case .progress(let done, let total):
            state.running?.phase = .transcribing; state.running?.fraction = min(0.99, done / max(1, total))
        case .finalized:
            break
        }
    }

    private func report(_ event: SpeakerAnalysisEvent, for id: UUID) {
        guard state.isRunning(id) else { return }
        switch event {
        case .preparingModels(let fraction):
            state.running?.phase = .preparingSpeakers(fraction); state.running?.fraction = fraction
        case .analyzing(let fraction):
            state.running?.phase = .identifyingSpeakers; state.running?.fraction = fraction
        }
    }

    private func finishRun() {
        if let backgroundToken { background.end(backgroundToken) }
        backgroundToken = nil
        state.running = nil
        task = nil
        processNext()
    }

    /// iOS takes the background time back: every job stops now, before the expiration handler returns.
    private func suspendAll() {
        for id in state.queue { cancel(id, failure: .interrupted) }
        if let running = state.running?.noteID { cancel(running, failure: .interrupted) }
    }
}
