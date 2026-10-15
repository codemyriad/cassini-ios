import Foundation
import Synchronization
import CassiniNotebook
#if os(iOS)
import os
#endif

/// What a job reads from the app's settings when it starts.
public struct JobSettings: Hashable, Sendable {
    /// Consent to download Apple's speech assets.
    public var allowSpeechDownload: Bool
    public var identifySpeakers: Bool
    /// Consent to download the speaker models.
    public var allowSpeakerDownload: Bool
    /// The Forget everyone generation when the job began; voiceprints are kept only while it is current.
    public var voicesGeneration: Int

    public init(allowSpeechDownload: Bool, identifySpeakers: Bool, allowSpeakerDownload: Bool, voicesGeneration: Int = 0) {
        self.allowSpeechDownload = allowSpeechDownload; self.identifySpeakers = identifySpeakers
        self.allowSpeakerDownload = allowSpeakerDownload; self.voicesGeneration = voicesGeneration
    }
}

/// The app's side of a job: its settings, and putting a speaker analysis into the note with the saved voices.
public protocol TranscriptionJobHost: Sendable {
    func jobSettings() async -> JobSettings
    /// Gives the note the analysed speakers and their matches; throws when the note could not be saved.
    func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws
}

/// One run of one job: the words with Parakeet Ultra (or, on a device that cannot hold it, Apple's speech analyzer),
/// read from where the last checkpoint stopped, then the speakers from the whole file.
///
/// - **Limits.** Audio over 36 h fails with `LONG` before any work; words that outgrow the word body of a Cassini
///   document fail with `LONG` at the checkpoint that passes it, keeping the one before; audio under 200 ms fails with
///   `SHORT`.
/// - **Checkpoints.** Parakeet saves `work/checkpoint.json` after each 28 s window (at most every 10 s) and resumes
///   from the window it saved; Apple Speech saves its finalized results once 30 s more audio is final (and at most every
///   10 s), resumes 1 s before the checkpoint and drops the words it already has. Both save at a stop and when the words
///   are complete; `JobEvent.checkpointed` follows each save that is on disk. A checkpoint that no longer matches the
///   audio or the recognizer (an Apple-era version 1 file, another language for Apple Speech) fails with
///   `CHECKPOINT_MISMATCH`.
/// - **Failures.** A recognizer that throws a `JobFailure` (`TIMINGS`, `MEMORY`, `MODEL`) fails with it; a cancellation
///   (`CancellationError`, `CANCELLED`) ends cancelled unless a pause asked for it.
/// - **Stop.** A pause keeps every finalized result (a stop before the first leaves no checkpoint); a cancel keeps
///   nothing new and the coordinator discards the work. A stop is noticed at the next result, or within 50 ms.
/// - **Speakers.** After the words are in the note, the speaker step analyses the whole file. A failure leaves every
///   word one voice (`speakerAnalysisFailure = SPEAKERS`) and the job still succeeds.
/// - **Provenance.** The run's record goes to the `ProvenanceStoring` with the words it describes (`ProvenanceRecord`),
///   not into the note. A speakers-only job adds its speaker record when the note still holds the run's words.
/// - **Work.** A transcribing job removes `work/` once the note is saved; a speakers-only job never touches it, so a
///   paused transcription keeps its checkpoint.
public struct TranscriptionJob: TranscriptionJobRunning {
    public struct Limits: Hashable, Sendable {
        public var maxDurationMs: Int64
        public var maxBodyBytes: Int64
        public var minDurationMs: Int64

        public init(maxDurationMs: Int64 = Int64(CassiniNotebook.Limits.maxTranscribeDuration * 1000),
                    maxBodyBytes: Int64 = TranscriptBudget.maxBytes, minDurationMs: Int64 = 200) {
            self.maxDurationMs = maxDurationMs; self.maxBodyBytes = maxBodyBytes; self.minDurationMs = minDurationMs
        }
    }

    private let notes: NoteStore
    private let transcriber: any Transcribing
    private let analyzer: any SpeakerAnalyzing
    private let checkpoints: any CheckpointStoring
    private let provenance: any ProvenanceStoring
    private let host: any TranscriptionJobHost
    private let clock: any AppClock
    private let limits: Limits
    private let uptimeMs: @Sendable () -> Int64
    private let availableMemory: @Sendable () -> Int64?
    private let device: @Sendable () -> RunDevice

    /// `availableMemory` is the memory left to Cassini, for the memory check at the start (`MemoryPreflight`);
    /// `device` the device and OS the provenance names.
    public init(notes: NoteStore, transcriber: any Transcribing, analyzer: any SpeakerAnalyzing,
                checkpoints: any CheckpointStoring, provenance: any ProvenanceStoring, host: any TranscriptionJobHost,
                clock: any AppClock, limits: Limits = Limits(),
                uptimeMs: @escaping @Sendable () -> Int64 = TranscriptionJob.uptimeMs,
                availableMemory: @escaping @Sendable () -> Int64? = TranscriptionJob.availableMemory,
                device: @escaping @Sendable () -> RunDevice = RunDevice.current) {
        self.notes = notes; self.transcriber = transcriber; self.analyzer = analyzer; self.checkpoints = checkpoints
        self.provenance = provenance; self.host = host; self.clock = clock; self.limits = limits
        self.uptimeMs = uptimeMs; self.availableMemory = availableMemory; self.device = device
    }

    /// `os_proc_available_memory()`: what Cassini can still allocate before iOS ends it; nil where the system does not
    /// tell (a Mac).
    @Sendable public static func availableMemory() -> Int64? {
        #if os(iOS)
        let bytes = os_proc_available_memory()
        return bytes > 0 ? Int64(bytes) : nil
        #else
        return nil
        #endif
    }

    /// Monotonic milliseconds.
    @Sendable public static func uptimeMs() -> Int64 {
        Int64(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) / 1_000_000)
    }

    public func run(_ job: Job, stop: StopSignal, events: @escaping @Sendable (JobEvent) -> Void) async -> JobOutcome {
        let outcome = await withTaskCancellationHandler {
            await pipeline(job, stop: stop, events: events)
        } onCancel: {
            stop.stop(.cancel)
        }
        events(.ended(outcome))
        return outcome
    }

    // MARK: - Pipeline

    private func pipeline(_ job: Job, stop: StopSignal, events: @escaping @Sendable (JobEvent) -> Void) async -> JobOutcome {
        guard let note = await notes.note(job.noteID) else { return .failed(.open) }
        let url = notes.audioURL(for: note)
        guard FileManager.default.fileExists(atPath: url.path) else { return .failed(.open) }
        // Too long or too short to transcribe: stop before any download or decode.
        let knownMs = CheckpointState.ms(note.duration)
        guard knownMs <= limits.maxDurationMs else { return .failed(.long) }
        guard knownMs == 0 || knownMs >= limits.minDurationMs else { return .failed(.short) }
        let settings = await host.jobSettings()
        let recognizer = transcriber.recognizer
        // Parakeet hears the language; only the Apple Speech fallback is given one.
        let language = recognizer.usesLanguage ? (job.language.isEmpty ? note.language : job.language) : ""
        let transcribes = job.kind != .speakersOnly

        var checkpoint: CheckpointState?
        if transcribes {
            let expected = CheckpointState.Expected(source: note.audioFilename, signature: CheckpointState.signature(of: url),
                                                    model: recognizer.checkpointModel(language: language))
            do {
                // A checkpoint of another version (Apple Speech before Ultra) or recognizer does not resume.
                checkpoint = try checkpoints.load(job.noteID)
                try checkpoint?.validate(expected)
            } catch {
                return .failed(.checkpointMismatch)
            }
            // A Parakeet checkpoint goes on from its window; one without it (none was written) starts over.
            if recognizer == .parakeet, checkpoint?.wordsComplete == false, checkpoint?.recognition == nil { checkpoint = nil }
            if checkpoint?.wordsComplete != true {
                switch await transcriber.assetStatus(locale: Locale(identifier: language)) {
                case .unsupported: return .failed(.unsupportedLanguage)
                case .ready, .downloading, .checking: break
                case .notDownloaded, .failed: if !settings.allowSpeechDownload { return .needsConsent(missingBytes: 0) }
                }
            }
        }
        let speakers = await analysesSpeakers(job.kind, settings)
        if let request = stop.request { return Self.outcome(of: request) }

        let restored = checkpoint.map {
            RestoredCheckpoint(doneMs: $0.doneMs, totalMs: $0.totalMs, words: $0.draftWords, elapsedMs: $0.elapsedMs)
        }
        let totalMs = checkpoint?.totalMs ?? knownMs
        events(.started(JobStart(totalMs: totalMs, restored: restored, speakers: speakers, prints: speakers,
                                 lowMemory: MemoryPreflight.lowMemory(durationMs: totalMs, availableBytes: availableMemory()))))
        var context = Context(noteID: job.noteID, url: url, source: note.audioFilename, language: language,
                              recognizer: recognizer, knownMs: knownMs, settings: settings, stop: stop, events: events)
        context.signature = CheckpointState.signature(of: url)

        if transcribes {
            var words = checkpoint
            if words?.wordsComplete != true {
                switch await decodeWords(context, from: checkpoint) {
                case .complete(let state, let segmentation): words = state; context.segmentation = segmentation
                case .ended(let outcome): return outcome
                }
            }
            events(.namingClosed(matching: speakers))
            guard let words, await saveTranscript(words, resumed: checkpoint?.wordsComplete == true, context) else {
                return .failed(.save)
            }
            context.totalMs = words.totalMs
        } else {
            events(.namingClosed(matching: speakers))
        }
        if speakers, let outcome = await identifySpeakers(context, modelsRequired: !transcribes) { return outcome }
        events(.stageChanged(.saving))
        if transcribes { try? checkpoints.discard(job.noteID) }
        return .done
    }

    private func analysesSpeakers(_ kind: JobKind, _ settings: JobSettings) async -> Bool {
        if kind == .speakersOnly { return true }
        guard settings.identifySpeakers else { return false }
        return settings.allowSpeakerDownload ? true : await analyzer.modelStatus() == .ready
    }

    static func outcome(of request: StopRequest) -> JobOutcome {
        switch request {
        case .pause(let reason): .paused(reason)
        case .cancel: .cancelled
        }
    }

    // MARK: - Words

    private enum WordsResult {
        /// The words, and how the recognizer cut the recording (Parakeet's `x-segmentation`).
        case complete(CheckpointState, segmentation: String?)
        case ended(JobOutcome)
    }

    private func decodeWords(_ context: Context, from checkpoint: CheckpointState?) async -> WordsResult {
        let resumeDoneMs = checkpoint?.doneMs ?? 0
        let parakeet = context.recognizer == .parakeet
        // Apple Speech starts again 1 s before the checkpoint; Parakeet reads up to its window and goes on from there.
        let startMs = resumeDoneMs == 0 ? 0
            : parakeet ? (checkpoint?.recognition?.start ?? 0) * 1000 / Int64(CassiniNotebook.Limits.asrRate)
            : AppleSpeechWindows.resumeStartMs(doneMs: resumeDoneMs)
        let decode = WordsDecode(
            base: checkpoint ?? CheckpointState(source: context.source, signature: context.signature,
                                                model: context.recognizer.checkpointModel(language: context.language),
                                                segments: [], doneMs: 0, totalMs: context.knownMs, elapsedMs: 0),
            noteID: context.noteID, resumeDoneMs: resumeDoneMs, recognizer: context.recognizer,
            language: context.language, limits: limits, checkpoints: checkpoints,
            stop: context.stop, events: context.events, uptimeMs: uptimeMs)
        context.events(.stageChanged(.reading, startMs: 0, endMs: startMs))
        context.events(.stageChanged(.preparing))
        let resume = parakeet ? checkpoint?.recognition.map { TranscriptResume(recognition: $0, words: checkpoint?.words ?? []) } : nil
        let request = TranscriptionRequest(url: context.url, language: context.language,
                                           startOffset: parakeet ? 0 : TimeInterval(startMs) / 1000, resume: resume,
                                           allowDownload: context.settings.allowSpeechDownload)
        let transcriber = transcriber
        let task = Task { try await transcriber.transcribe(request) { decode.handle($0) } }
        decode.attach(task)
        let watch = StopWatch.start(context.stop) { decode.stopRequested($0) }
        let result = await task.result
        watch.cancel()
        switch decode.finish(result) {
        case .complete(let state): return .complete(state, segmentation: try? result.get().segmentation)
        case .stopped(let request): return .ended(Self.outcome(of: request))
        case .failed(let failure): return .ended(.failed(failure))
        case .downloadFailed(let failure): return .ended(.downloadFailed(failure))
        case .needsConsent: return .ended(.needsConsent(missingBytes: 0))
        }
    }

    /// Puts the words into the note as a new version, even when they equal the transcript shown (as Android adds a
    /// variant for every transcription), and records their provenance. A run that resumed for its speaker step finds
    /// them saved already (the record describes them) and leaves the note as it is, edits and all.
    private func saveTranscript(_ words: CheckpointState, resumed: Bool, _ context: Context) async -> Bool {
        let segments = words.segments
        if resumed, provenance.load(context.noteID)?.describes(segments) == true { return true }
        let run: TranscriptProvenance
        switch context.recognizer {
        case .parakeet:
            // A run that resumed with every word already decoded asks the transcriber how it cuts the audio.
            let segmentation = if let known = context.segmentation { known } else { await transcriber.segmentation() }
            run = .parakeetRun(model: "\(ModelCatalog.parakeetModelID) \(ModelCatalog.parakeetPrecision)",
                               revision: ModelCatalog.parakeetRevision, segmentation: segmentation ?? "",
                               inferenceMs: words.inferenceMs, resumedFromMs: words.resumedFromMs, device: device())
        case .appleSpeech:
            let model = await transcriber.modelName(locale: Locale(identifier: context.language))
            run = .appleRun(language: context.language, inferenceMs: words.inferenceMs, resumedFromMs: words.resumedFromMs,
                            model: model, device: device())
        }
        let record = ProvenanceRecord(provenance: run, transcript: segments)
        let date = clock.now, before = UUID(), after = UUID()
        do {
            let saved = try await notes.mutate(context.noteID) { note in
                note.saveCurrentVersion(.previous, id: before, date: date)
                note.transcript = segments
                note.speakers = []
                note.selectedVersionID = nil
                note.saveCurrentVersion(.transcription, id: after, date: date)
                note.failure = nil
                note.speakerAnalysisFailure = nil
            }
            guard saved != nil else { return false }
            try provenance.save(record, for: context.noteID)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Speakers

    /// The speaker step; nil when the job goes on to save, else how it ended. The speaker models are best effort for a
    /// transcription (every word stays one voice without them); a speakers-only job, which has nothing else to do,
    /// ends with their download failure or missing consent instead.
    private func identifySpeakers(_ context: Context, modelsRequired: Bool) async -> JobOutcome? {
        let events = context.events
        let totalMs = max(context.totalMs, context.knownMs)
        events(.stageChanged(.speakers, startMs: 0, endMs: 0))
        let analyzer = analyzer, url = context.url, allowDownload = context.settings.allowSpeakerDownload
        let task = Task {
            try await analyzer.analyze(url: url, allowDownload: allowDownload) { event in
                switch event {
                case .preparingModels(.downloading(let fraction)):
                    events(.downloading(fraction.map(Self.fractionProgress(.speakers))))
                case .preparingModels(.checking):
                    events(.downloading(DownloadProgress(part: .speakers, doneBytes: 0, totalBytes: 0, verifying: true)))
                case .analyzing(let fraction):
                    events(.stageChanged(.speakers, startMs: 0, endMs: Int64(Double(totalMs) * min(max(fraction, 0), 1))))
                }
            }
        }
        let stopped = StopLatch()
        let watch = StopWatch.start(context.stop) { request in
            stopped.set(request)
            events(.stopping)
            task.cancel()
        }
        let result = await task.result
        watch.cancel()
        if let request = stopped.value ?? context.stop.request { return Self.outcome(of: request) }
        let analysis: SpeakerAnalysis
        switch result {
        case .success(let value):
            analysis = value
        case .failure(SpeakerAnalysisError.download(let error, let bytes)) where modelsRequired:
            return .downloadFailed(DownloadFailure(error: error, part: .speakers, requiredFreeBytes: bytes))
        case .failure(SpeakerAnalysisError.needsConsent) where modelsRequired:
            return .needsConsent(missingBytes: 0)
        case .failure:
            return await speakersFailed(context)
        }
        events(.stageChanged(.matching))
        do {
            try await host.applySpeakers(analysis, to: context.noteID, generation: context.settings.voicesGeneration)
        } catch {
            return await speakersFailed(context)
        }
        await recordSpeakers(analysis, context)
        return nil
    }

    /// Adds the speaker record to the provenance of the words the analysis was given, with the counts of its matches
    /// (`x-speakerIdentification`) when it made prints.
    private func recordSpeakers(_ analysis: SpeakerAnalysis, _ context: Context) async {
        guard let note = await notes.note(context.noteID), var record = provenance.load(context.noteID),
              record.describes(note.transcript) else { return }
        var identity = analysis.prints.first?.model
        if identity == nil { identity = await analyzer.modelIdentity }
        guard let identity else { return }
        let diarization = TranscriptProvenance.SpeakerDiarization(
            identity: identity, backend: analysis.backend ?? TranscriptProvenance.SpeakerDiarization.fluidAudio,
            modelRevision: analysis.modelRevision, elapsedMs: analysis.elapsedMs, turnCount: analysis.turns.count,
            speakerCount: Set(analysis.turns.map(\.speakerID)).count)
        record.addSpeakers(diarization, identification: Self.identification(analysis, note), transcript: note.transcript)
        try? provenance.save(record, for: context.noteID)
    }

    /// The match counts of `analysis` as `note` took them: speakers named automatically from a saved voice (an
    /// automatic or confirmed link), and speakers only offered one. Nil without prints.
    static func identification(_ analysis: SpeakerAnalysis, _ note: Note) -> TranscriptProvenance.SpeakerIdentification? {
        guard let first = analysis.prints.first else { return nil }
        let shown = Set(note.transcript.compactMap(\.speakerID))
        let speakers = (note.speakers ?? []).filter { shown.contains($0.id) }
        var automatic = 0, suggested = 0
        for speaker in speakers {
            switch speaker.match {
            case .auto, .confirmed: automatic += 1
            case .suggested: suggested += 1
            default: break
            }
        }
        return TranscriptProvenance.SpeakerIdentification(
            identity: first.model, dim: first.vector.count, thresholds: .ios, speakersWithPrints: analysis.prints.count,
            autoApplied: automatic, suggested: suggested)
    }

    /// Every word stays one voice; the job still succeeds.
    private func speakersFailed(_ context: Context) async -> JobOutcome? {
        context.events(.speakersUnavailable)
        _ = try? await notes.mutate(context.noteID) { $0.speakerAnalysisFailure = .speakers }
        return nil
    }

    static func fractionProgress(_ part: ModelPart) -> @Sendable (Double) -> DownloadProgress {
        { fraction in
            DownloadProgress(part: part, doneBytes: Int64((min(max(fraction, 0), 1) * 1000).rounded()), totalBytes: 1000,
                             verifying: false)
        }
    }

    /// What one run knows about its note.
    private struct Context: Sendable {
        let noteID: UUID
        let url: URL
        let source: String
        /// BCP-47 for Apple Speech; `""` for Parakeet.
        let language: String
        let recognizer: SpeechRecognizer
        let knownMs: Int64
        let settings: JobSettings
        let stop: StopSignal
        let events: @Sendable (JobEvent) -> Void
        var signature = ""
        var totalMs: Int64 = 0
        var segmentation: String?

        init(noteID: UUID, url: URL, source: String, language: String, recognizer: SpeechRecognizer, knownMs: Int64,
             settings: JobSettings, stop: StopSignal, events: @escaping @Sendable (JobEvent) -> Void) {
            self.noteID = noteID; self.url = url; self.source = source; self.language = language
            self.recognizer = recognizer; self.knownMs = knownMs; self.settings = settings; self.stop = stop
            self.events = events
        }
    }
}

/// Polls a `StopSignal` and calls `onStop` once when a stop is asked.
enum StopWatch {
    static let interval = Duration.milliseconds(50)

    static func start(_ stop: StopSignal, onStop: @escaping @Sendable (StopRequest) -> Void) -> Task<Void, Never> {
        Task.detached {
            while !Task.isCancelled {
                if let request = stop.request { onStop(request); return }
                try? await Task.sleep(for: interval)
            }
        }
    }
}

/// The stop a step saw, set from the stop watch.
final class StopLatch: Sendable {
    private let request = Mutex<StopRequest?>(nil)
    var value: StopRequest? { request.withLock { $0 } }
    func set(_ value: StopRequest) { request.withLock { $0 = value } }
}
