import CassiniCore
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
    /// "Name strong matches automatically": a live match names a draft speaker only when it is on.
    public var automaticallyNameVoices: Bool

    public init(allowSpeechDownload: Bool, identifySpeakers: Bool, allowSpeakerDownload: Bool, voicesGeneration: Int = 0,
                automaticallyNameVoices: Bool = false) {
        self.allowSpeechDownload = allowSpeechDownload; self.identifySpeakers = identifySpeakers
        self.allowSpeakerDownload = allowSpeakerDownload; self.voicesGeneration = voicesGeneration
        self.automaticallyNameVoices = automaticallyNameVoices
    }
}

/// The app's side of a job: its settings, and putting a speaker analysis into the note with the saved voices.
public protocol TranscriptionJobHost: Sendable {
    func jobSettings() async -> JobSettings
    /// Gives the note the analysed speakers and their matches; throws when the note could not be saved.
    func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws
    /// The saved voices as they are whenever it is called, from any thread, for live matching: none once Forget
    /// everyone moved past `generation`.
    func liveVoices(generation: Int) async -> @Sendable () -> [SavedVoice]
}

extension TranscriptionJobHost {
    public func liveVoices(generation: Int) async -> @Sendable () -> [SavedVoice] { { [] } }
}

/// One run of one job: the words with Parakeet Ultra (or, on a device that cannot hold it, Apple's speech analyzer),
/// read from where the last checkpoint stopped, and the speakers.
///
/// - **Limits.** Audio over 36 h fails with `LONG` before any work; words that outgrow the word body of a Cassini
///   document fail with `LONG` at the checkpoint that passes it, keeping the one before; audio under 200 ms fails with
///   `SHORT`.
/// - **Checkpoints.** Parakeet saves `work/checkpoint.json` after each 28 s window (at most every 10 s) and resumes
///   from the window it saved; Apple Speech saves its finalized results once 30 s more audio is final (and at most every
///   10 s), resumes 1 s before the checkpoint and drops the words it already has. Both save at a stop and when the words
///   are complete; `JobEvent.checkpointed` follows each save that is on disk. A checkpoint that no longer matches the
///   audio or the recognizer (another version, model, or language for Apple Speech) fails with
///   `CHECKPOINT_MISMATCH`.
/// - **Failures.** A recognizer that throws a `JobFailure` (`TIMINGS`, `MEMORY`, `MODEL`) fails with it; a cancellation
///   (`CancellationError`, `CANCELLED`) ends cancelled unless a pause asked for it.
/// - **Stop.** A pause keeps every finalized result (a stop before the first leaves no checkpoint); a cancel keeps
///   nothing new and the coordinator discards the work. A stop is noticed at the next result, or within 50 ms.
/// - **Native budget.** The decode, the voiceprints and a whole-file speaker analysis each hold `NativeBudget`, so a
///   cancelled job's native models are gone before the next job loads its own ("Finishing the previous note…").
/// - **Speakers, as Parakeet decodes (Android's pipeline).** The speaker models are installed before the decode (best
///   effort, with the speaker consent). Each window's words get their speakers from streaming Sortformer
///   (`WindowSpeakers`), so the draft shows them, and the speaker state, the voice clips (`work/clips.pcm`) and the
///   words are checkpointed together. After the decode the CAM++ prints of the clips are matched with the saved voices
///   and the note gets the words with their speakers. A speaker failure gives the later windows one voice and never
///   fails the job; without any turn every word stays one voice (`speakerAnalysisFailure = SPEAKERS`).
/// - **Speakers after the words.** A speakers-only job (Identify speakers), an Apple Speech transcription, and a
///   Parakeet run resumed from a checkpoint that did not stream speakers analyse the whole file after the words are in
///   the note (`SpeakerAnalyzing.analyze`). A failure leaves every word one voice and the job still succeeds.
/// - **Draft names (Android's `names.json`).** A streaming run opens naming (`DraftNamesStore`); a fresh one starts
///   with no names. Each window ends with a round of live voice matching (`LiveMatching`). Once the words are done the
///   job closes naming and puts the names into the note with the speakers: the draft merges, the user's labels, the
///   rejected voices (never matched) and the Remember choices (enrolled once the note is saved). A run that closed
///   naming and does not finish opens it again.
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
    private let budget: NativeBudget
    private let uptimeMs: @Sendable () -> Int64
    private let availableMemory: @Sendable () -> Int64?
    private let device: @Sendable () -> RunDevice
    private let drafts: DraftNamesStore?

    /// `availableMemory` is the memory left to Cassini, for the memory check at the start (`MemoryPreflight`) and the
    /// speaker models' (`SpeakerMemory`); `device` the device and OS the provenance names; `budget` the native budget
    /// the decode and the speaker models hold; `drafts` the draft names (nil: the draft has no names).
    public init(notes: NoteStore, transcriber: any Transcribing, analyzer: any SpeakerAnalyzing,
                checkpoints: any CheckpointStoring, provenance: any ProvenanceStoring, host: any TranscriptionJobHost,
                clock: any AppClock, limits: Limits = Limits(), budget: NativeBudget = .shared,
                drafts: DraftNamesStore? = nil,
                uptimeMs: @escaping @Sendable () -> Int64 = TranscriptionJob.uptimeMs,
                availableMemory: @escaping @Sendable () -> Int64? = TranscriptionJob.availableMemory,
                device: @escaping @Sendable () -> RunDevice = RunDevice.current) {
        self.notes = notes; self.transcriber = transcriber; self.analyzer = analyzer; self.checkpoints = checkpoints
        self.provenance = provenance; self.host = host; self.clock = clock; self.limits = limits; self.budget = budget
        self.uptimeMs = uptimeMs; self.availableMemory = availableMemory; self.device = device
        self.drafts = drafts
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
        if let drafts, job.kind != .speakersOnly {
            // The names went into the note, or the work goes: the next use reads names.json again. A run that stops
            // keeps them, open for naming.
            switch outcome {
            case .done, .cancelled: drafts.release(job.noteID)
            default: drafts.open(job.noteID)
            }
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
        // Parakeet hears the language; only the Apple Speech fallback is given one: the job's, else the one its saved
        // progress began in (a rebuilt queue's job has none), never the note's, which is the language of its words.
        let language = !recognizer.usesLanguage ? ""
            : job.language.isEmpty ? ((try? checkpoints.load(job.noteID))??.appleLanguage ?? "") : job.language
        let transcribes = job.kind != .speakersOnly

        var checkpoint: CheckpointState?
        if transcribes {
            let expected = CheckpointState.Expected(source: note.audioFilename, signature: CheckpointState.signature(of: url),
                                                    model: recognizer.checkpointModel(language: language))
            do {
                // A checkpoint of another version or recognizer does not resume.
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

        var context = Context(noteID: job.noteID, url: url, source: note.audioFilename, language: language,
                              recognizer: recognizer, knownMs: knownMs, settings: settings, stop: stop, events: events)
        context.signature = CheckpointState.signature(of: url)
        if transcribes {
            context.wordsLanguage = TranscriptLanguage.ofRun(reported: await transcriber.runLanguage(requested: language))
        }
        context.availableMemory = availableMemory
        context.clipsURL = checkpoints.clipsURL(for: job.noteID)
        let plan: SpeakerPlan
        switch await speakerPlan(speakers: speakers, transcribes: transcribes, checkpoint: checkpoint, context) {
        case .plan(let value): plan = value
        case .ended(let outcome): return outcome
        }
        if case .streaming = plan, let drafts {
            // Every streaming run starts with naming open; a fresh one with no names (there are no words to name yet).
            drafts.open(job.noteID)
            if checkpoint == nil {
                drafts.mutate(job.noteID) { _ in DraftNames(generation: settings.voicesGeneration) }
            }
            context.live = await host.liveVoices(generation: settings.voicesGeneration)
        }
        context.drafts = drafts
        let decodes = transcribes && checkpoint?.wordsComplete != true
        // The decode holds the native budget from before the run starts, so a job that waits for the previous one's
        // models to go shows "Finishing the previous note…".
        let holdsBudget = decodes && recognizer == .parakeet
        if holdsBudget, let request = await takeBudget(context) { return Self.outcome(of: request) }
        var released = !holdsBudget
        defer { if !released { budget.release() } }

        let restored = checkpoint.map {
            RestoredCheckpoint(doneMs: $0.doneMs, totalMs: $0.totalMs, words: $0.draftWords, elapsedMs: $0.elapsedMs)
        }
        let totalMs = checkpoint?.totalMs ?? knownMs
        events(.started(JobStart(totalMs: totalMs, restored: restored, speakers: plan.runs, prints: plan.printsReady,
                                 lowMemory: MemoryPreflight.lowMemory(durationMs: totalMs, availableBytes: availableMemory()),
                                 matching: plan.runs && plan.printsReady)))
        if plan.failedBeforeDecode { events(.speakersUnavailable) }

        var streamed: StreamedSpeakers?
        if transcribes {
            var words = checkpoint
            if words?.wordsComplete != true {
                let window = plan.windowSpeakers(context, restored: checkpoint?.speakers)
                switch await decodeWords(context, from: checkpoint, speakers: window?.speakers) {
                case .complete(let state, let segmentation): words = state; context.segmentation = segmentation
                case .ended(let outcome): return outcome
                }
                streamed = window.map { StreamedSpeakers(window: $0.speakers, engines: $0.engines, printsReady: $0.printsReady) }
            } else if case .streaming(let engines, let printsReady) = plan, let saved = checkpoint?.speakers {
                // Stopped after the words: the speakers go on from the complete checkpoint.
                streamed = StreamedSpeakers(saved: saved, engines: engines, printsReady: printsReady, context, checkpoints)
            }
            if holdsBudget {
                budget.release()
                released = true
            }
            if streamed != nil { streamed?.names = drafts?.close(job.noteID) }
            events(.namingClosed(matching: plan.runs && plan.printsReady))
            guard let words, await saveTranscript(words, resumed: checkpoint?.wordsComplete == true, context) else {
                return .failed(.save)
            }
            context.totalMs = words.totalMs
            context.attributed = words.segments
        } else {
            events(.namingClosed(matching: speakers))
        }
        if plan.runs {
            let outcome = if let streamed {
                await streamedSpeakers(streamed, context)
            } else {
                await identifySpeakers(context, modelsRequired: !transcribes)
            }
            if let outcome { return outcome }
        } else if plan.failedBeforeDecode {
            _ = try? await notes.mutate(context.noteID) { $0.speakerAnalysisFailure = .speakers }
        }
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

    /// Waits for the native budget, showing "Finishing the previous note…" while another holds it. A stop ends the
    /// wait: its request comes back and the budget is not held. Nil once the budget is held.
    private func takeBudget(_ context: Context) async -> StopRequest? {
        if budget.isHeld { context.events(.waitingForPrevious) }
        let budget = budget
        let task = Task { try await budget.acquire() }
        let watch = StopWatch.start(context.stop) { _ in task.cancel() }
        let result = await task.result
        watch.cancel()
        switch result {
        case .success:
            if let request = context.stop.request {
                budget.release()
                return request
            }
            return nil
        case .failure:
            return context.stop.request ?? .cancel
        }
    }

    // MARK: - Words

    private enum WordsResult {
        /// The words, and how the recognizer cut the recording (Parakeet's `x-segmentation`).
        case complete(CheckpointState, segmentation: String?)
        case ended(JobOutcome)
    }

    private func decodeWords(_ context: Context, from checkpoint: CheckpointState?,
                             speakers: WindowSpeakers?) async -> WordsResult {
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
            language: context.wordsLanguage, limits: limits, checkpoints: checkpoints,
            stop: context.stop, events: context.events, uptimeMs: uptimeMs)
        context.events(.stageChanged(.reading, startMs: 0, endMs: startMs))
        context.events(.stageChanged(.preparing))
        let resume = parakeet ? checkpoint?.recognition.map { TranscriptResume(recognition: $0, words: checkpoint?.words ?? []) } : nil
        let request = TranscriptionRequest(url: context.url, language: context.language,
                                           startOffset: parakeet ? 0 : TimeInterval(startMs) / 1000, resume: resume,
                                           allowDownload: context.settings.allowSpeechDownload,
                                           speakers: parakeet ? speakers : nil)
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
    /// them saved already (the record describes them) and leaves the note as it is, edits and all. The words go in
    /// with one voice: the speaker step gives them their speakers, the streamed ones too.
    private func saveTranscript(_ words: CheckpointState, resumed: Bool, _ context: Context) async -> Bool {
        let segments = words.segments.map { segment in
            var plain = segment
            plain.speakerID = nil
            plain.speaker = nil
            return plain
        }
        if resumed, provenance.load(context.noteID)?.describes(segments) == true { return true }
        let language = context.wordsLanguage
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
            run = .appleRun(language: language, inferenceMs: words.inferenceMs, resumedFromMs: words.resumedFromMs,
                            model: model, device: device())
        }
        let record = ProvenanceRecord(provenance: run, transcript: segments)
        let date = clock.now, before = UUID(), after = UUID()
        do {
            let saved = try await notes.mutate(context.noteID) { note in
                note.saveCurrentVersion(.previous, id: before, date: date)
                note.transcript = segments
                note.language = language
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

    /// How the speakers of a run are told apart.
    private enum SpeakerPlan {
        /// Not at all (the setting is off or the models are missing without consent).
        case none
        /// Streaming Sortformer while Parakeet decodes; `printsReady` when CAM++ is installed.
        case streaming(any SpeakerEngines, printsReady: Bool)
        /// The whole file after the words (`SpeakerAnalyzing.analyze`).
        case afterWords
        /// The speaker models could not be installed or loaded before the decode: every word is one voice.
        case failed

        var runs: Bool {
            switch self {
            case .streaming, .afterWords: true
            case .none, .failed: false
            }
        }

        var printsReady: Bool {
            switch self {
            case .streaming(_, let ready): ready
            case .afterWords: true
            case .none, .failed: false
            }
        }

        var failedBeforeDecode: Bool { if case .failed = self { true } else { false } }

        /// The window speakers of the decode, for a streaming plan; a checkpoint's speaker state is restored, and
        /// clips it counts that are not on disk any more leave the run without prints.
        func windowSpeakers(_ context: TranscriptionJob.Context, restored: SpeakerCheckpoint?)
            -> (speakers: WindowSpeakers, engines: any SpeakerEngines, printsReady: Bool)? {
            guard case .streaming(let engines, let printsReady) = self else { return nil }
            let events = context.events
            let failure: @Sendable () -> Void = { events(.speakersUnavailable) }
            let live = context.drafts.map {
                LiveMatching(noteID: context.noteID, drafts: $0, voices: context.live,
                             autoName: context.settings.automaticallyNameVoices)
            }
            if printsReady, let clips = context.openClips(keeping: restored?.clipSamples ?? 0, fresh: restored == nil),
               let speakers = try? WindowSpeakers(engines: engines, clips: clips, restored: restored,
                                                  availableMemory: context.availableMemory, live: live,
                                                  onFailure: failure) {
                return (speakers, engines, true)
            }
            var withoutClips = restored
            withoutClips?.voiceClips = [:]
            guard let speakers = try? WindowSpeakers(engines: engines, clips: nil, restored: withoutClips,
                                                     availableMemory: context.availableMemory, onFailure: failure)
            else { return nil }
            return (speakers, engines, false)
        }
    }

    private enum PlanResult {
        case plan(SpeakerPlan)
        case ended(JobOutcome)
    }

    /// Android's `installModels` for the speaker parts: a Parakeet run that will decode installs the speaker models
    /// first when the speaker consent allows it (best effort: a failure gives every word one voice), then streams.
    /// A Parakeet checkpoint whose speakers were not streamed, an Apple Speech run and a speakers-only job analyse the
    /// whole file after the words.
    private func speakerPlan(speakers: Bool, transcribes: Bool, checkpoint: CheckpointState?,
                             _ context: Context) async -> PlanResult {
        guard speakers else { return .plan(.none) }
        guard transcribes, context.recognizer == .parakeet else { return .plan(.afterWords) }
        let complete = checkpoint?.wordsComplete == true
        // Words decoded before without streamed speakers get theirs from the whole file.
        if checkpoint != nil, checkpoint?.speakers == nil { return .plan(.afterWords) }
        if !complete, await analyzer.modelStatus() != .ready {
            guard context.settings.allowSpeakerDownload else { return .plan(.failed) }
            let events = context.events
            let task = Task {
                try await analyzer.installModels { progress in
                    switch progress {
                    case .downloading(let fraction): events(.downloading(fraction.map(Self.fractionProgress(.speakers))))
                    case .checking:
                        events(.downloading(DownloadProgress(part: .speakers, doneBytes: 0, totalBytes: 0, verifying: true)))
                    }
                }
            }
            let watch = StopWatch.start(context.stop) { _ in task.cancel() }
            let result = await task.result
            watch.cancel()
            if let request = context.stop.request { return .ended(Self.outcome(of: request)) }
            if case .failure = result { return .plan(.failed) }
        }
        guard let engines = await analyzer.streamingEngines() else { return .plan(complete ? .afterWords : .failed) }
        return .plan(.streaming(engines, printsReady: await analyzer.printsReady()))
    }

    /// The speakers a Parakeet run streamed, for the step after its words.
    private struct StreamedSpeakers {
        let turns: [DiarizerTurn]
        let prefix: String
        let failed: Bool
        let elapsedMs: Int64
        let clips: (any ClipStore)?
        let windows: [String: [PrintWindow]]
        let engines: any SpeakerEngines
        let printsReady: Bool
        /// The draft names, closed once the words are done.
        var names: DraftNames?

        init(window: WindowSpeakers, engines: any SpeakerEngines, printsReady: Bool) {
            turns = window.turns; prefix = window.prefix; failed = window.failed; elapsedMs = window.elapsedMs
            clips = window.clipAudio; windows = window.clipWindows; self.engines = engines
            self.printsReady = printsReady && window.clipAudio != nil
        }

        /// From a complete checkpoint: its turns, and its clips when they are still on disk.
        init(saved: SpeakerCheckpoint, engines: any SpeakerEngines, printsReady: Bool, _ context: Context,
             _ checkpoints: any CheckpointStoring) {
            turns = saved.diarizer?.turns ?? []; prefix = saved.prefix; failed = saved.failed
            elapsedMs = saved.diarizer?.elapsedMs ?? 0; self.engines = engines
            let clips = printsReady ? context.openClips(keeping: saved.clipSamples, fresh: false) : nil
            self.clips = clips
            windows = clips == nil ? [:] : saved.voiceClips
            self.printsReady = clips != nil
        }
    }

    /// After the decode of a streaming run: the CAM++ prints of the clips (best effort, under the native budget), then
    /// the words with their speakers and the matches go into the note. Nil when the job goes on to save.
    private func streamedSpeakers(_ streamed: StreamedSpeakers, _ context: Context) async -> JobOutcome? {
        let events = context.events
        guard !(streamed.failed && streamed.turns.isEmpty) else {
            await speakersFailed(context)
            return nil
        }
        events(.stageChanged(.matching))
        // The draft merges: one print per shown speaker, from the clips of every speaker merged into it.
        let names = streamed.names ?? .empty
        let windows = names.merged(streamed.windows)
        var prints: [SpeakerPrint] = []
        if streamed.printsReady, let clips = streamed.clips, !windows.isEmpty {
            if let request = await takeBudget(context) { return Self.outcome(of: request) }
            let engines = streamed.engines, memory = availableMemory
            let made = try? await engines.run { () throws -> [String: Voiceprint] in
                guard SpeakerMemory.allows(availableBytes: memory(), SpeakerMemory.beforePrintsBytes) else { return [:] }
                return try CheckedPrints.check(engines.prints(clips, windows: windows) { try Task.checkCancellation() })
            }
            budget.release()
            if let request = context.stop.request { return Self.outcome(of: request) }
            prints = (made ?? [:]).sorted { $0.key < $1.key }.map {
                SpeakerPrint(speakerID: $0.key, model: VoiceprintModel.sha256, vector: $0.value.vector,
                             speechSeconds: $0.value.seconds)
            }
        }
        let turns = streamed.turns.map { turn in
            var shown = turn.speakerTurn(prefix: streamed.prefix)
            shown.speakerID = names.resolve(shown.speakerID)
            return shown
        }
        let transcript = context.attributed?.map { segment in
            var shown = segment
            shown.speakerID = segment.speakerID.map(names.resolve)
            return shown
        }
        let analysis = SpeakerAnalysis(turns: turns, prints: prints, transcript: transcript, elapsedMs: streamed.elapsedMs,
                                       streaming: true, printsReady: streamed.printsReady,
                                       names: streamed.names)
        return await applyAnalysis(analysis, context)
    }

    /// The speaker step after the words: the whole file. Nil when the job goes on to save, else how it ended. The
    /// speaker models are best effort for a transcription (every word stays one voice without them); a speakers-only
    /// job, which has nothing else to do, ends with their download failure or missing consent instead.
    private func identifySpeakers(_ context: Context, modelsRequired: Bool) async -> JobOutcome? {
        let events = context.events
        let totalMs = max(context.totalMs, context.knownMs)
        events(.stageChanged(.speakers, startMs: 0, endMs: 0))
        let analyzer = analyzer, url = context.url, allowDownload = context.settings.allowSpeakerDownload
        let words = await notes.note(context.noteID).map { Self.words(of: $0.transcript) } ?? []
        let report: @Sendable (SpeakerAnalysisEvent) -> Void = { event in
            switch event {
            case .preparingModels(.downloading(let fraction)):
                events(.downloading(fraction.map(Self.fractionProgress(.speakers))))
            case .preparingModels(.checking):
                events(.downloading(DownloadProgress(part: .speakers, doneBytes: 0, totalBytes: 0, verifying: true)))
            case .analyzing(let fraction):
                events(.stageChanged(.speakers, startMs: 0, endMs: Int64(Double(totalMs) * min(max(fraction, 0), 1))))
            }
        }
        // The models are installed before the budget is taken, so a download never holds it.
        let budget = budget
        let task = Task { () throws -> SpeakerAnalysis in
            if await analyzer.modelStatus() != .ready {
                guard allowDownload else { throw SpeakerAnalysisError.needsConsent }
                try await analyzer.installModels { report(.preparingModels($0)) }
            }
            return try await budget.withBudget {
                try await analyzer.analyze(url: url, words: words, allowDownload: allowDownload, progress: report)
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
        return await applyAnalysis(analysis, context)
    }

    /// The note's words as the analysis reads them: a passage without word times is one word.
    static func words(of transcript: [TranscriptSegment]) -> [Word] {
        transcript.flatMap { segment in segment.draftWords.map { Word($0.speaker, $0.startMs, $0.endMs, $0.text) } }
    }

    /// Puts `analysis` into the note with its matches, then records it.
    private func applyAnalysis(_ analysis: SpeakerAnalysis, _ context: Context) async -> JobOutcome? {
        do {
            try await host.applySpeakers(analysis, to: context.noteID, generation: context.settings.voicesGeneration)
        } catch {
            return await speakersFailed(context)
        }
        await recordSpeakers(analysis, context)
        return nil
    }

    /// Adds the speaker record to the provenance of the words the analysis was given (Android's
    /// `SpeakerAttribution.record` for Sortformer), with the counts of its matches (`x-speakerIdentification`) when the
    /// voiceprint model ran.
    private func recordSpeakers(_ analysis: SpeakerAnalysis, _ context: Context) async {
        guard let note = await notes.note(context.noteID), var record = provenance.record(of: note.transcript, in: context.noteID),
              !analysis.turns.isEmpty else { return }
        let speakers = Set(note.transcript.compactMap(\.speakerID)).count
        guard speakers > 0 else { return }
        let diarization = TranscriptProvenance.SpeakerDiarization.sortformer(
            revision: ModelCatalog.diarizationSourceRevision, sha256: ModelCatalog.diarizationModel.sha256,
            elapsedMs: analysis.elapsedMs ?? 0, turnCount: analysis.turns.count, speakerCount: speakers,
            streaming: analysis.streaming)
        record.addSpeakers(diarization, identification: Self.identification(analysis, note), transcript: note.transcript)
        try? provenance.save(record, for: context.noteID)
    }

    /// The match counts of `analysis` as `note` took them: speakers named automatically from a saved voice (an
    /// automatic or confirmed link), and speakers only offered one. Nil when the voiceprint model did not run.
    static func identification(_ analysis: SpeakerAnalysis, _ note: Note) -> TranscriptProvenance.SpeakerIdentification? {
        guard analysis.printsReady || !analysis.prints.isEmpty else { return nil }
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
        return .campplus(dim: analysis.prints.first?.vector.count ?? VoiceprintModel.dimension,
                         speakersWithPrints: analysis.prints.count, autoApplied: automatic, suggested: suggested)
    }

    /// Every word stays one voice; the job still succeeds.
    @discardableResult
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
    struct Context: Sendable {
        let noteID: UUID
        let url: URL
        let source: String
        /// The language the recognizer is asked for: BCP-47 for Apple Speech; `""` for Parakeet.
        let language: String
        /// The language the run's words are written with (D53.2): the locale Apple Speech runs in, `und` for Parakeet.
        var wordsLanguage = TranscriptLanguage.undetermined
        let recognizer: SpeechRecognizer
        let knownMs: Int64
        let settings: JobSettings
        let stop: StopSignal
        let events: @Sendable (JobEvent) -> Void
        var signature = ""
        var totalMs: Int64 = 0
        var segmentation: String?
        /// The words of a streaming run with their speakers, once they are complete.
        var attributed: [TranscriptSegment]?
        var availableMemory: @Sendable () -> Int64? = { nil }
        var clipsURL: URL?
        /// The draft names, and the saved voices for live matching.
        var drafts: DraftNamesStore?
        var live: @Sendable () -> [SavedVoice] = { [] }

        init(noteID: UUID, url: URL, source: String, language: String, recognizer: SpeechRecognizer, knownMs: Int64,
             settings: JobSettings, stop: StopSignal, events: @escaping @Sendable (JobEvent) -> Void) {
            self.noteID = noteID; self.url = url; self.source = source; self.language = language
            self.recognizer = recognizer; self.knownMs = knownMs; self.settings = settings; self.stop = stop
            self.events = events
        }

        /// The note's voice clips: `work/clips.pcm` cut back to `keeping` samples (emptied for a `fresh` run), or
        /// memory when the job keeps no work files. Nil when the file cannot be opened or holds fewer samples.
        func openClips(keeping: Int, fresh: Bool) -> (any ClipStore)? {
            guard let clipsURL else { return fresh ? MemoryClips() : nil }
            return try? ClipFile(url: clipsURL, keeping: fresh ? nil : keeping)
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
