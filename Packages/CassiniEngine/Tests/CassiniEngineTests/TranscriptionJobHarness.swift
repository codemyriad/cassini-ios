import CassiniCore
import Foundation
import Synchronization
import Testing
import CassiniEngine
import CassiniEngineTesting
import CassiniNotebook

/// The scripted transcriber, the host and the files a `TranscriptionJobTests` job runs over.
extension TranscriptionJobTests {
    struct Harness {
        let root: URL
        let notes: NoteStore
        let noteID = UUID()
        let audioURL: URL
        let files: CheckpointFiles
        let checkpoints: RecordingCheckpoints
        let provenanceFiles: ProvenanceFiles
        let transcriber: ScriptedTranscriber
        let analyzer: any SpeakerAnalyzing
        let host: FakeHost
        let limits: TranscriptionJob.Limits
        /// The native budget the job holds; its own, so tests that run side by side do not wait for each other.
        let budget = NativeBudget()
        /// Runs the job with this transcriber in place of `transcriber` (a Parakeet one, say).
        let engine: (any Transcribing)?

        var applied: [(noteID: UUID, generation: Int)] { host.applied }

        init(duration: TimeInterval = 70, reportsTotal: Bool = true, script: [TranscriptSegment] = ScriptedTranscriber.seventySeconds,
             speechStatus: ModelPartStatus = .ready, analyzer: any SpeakerAnalyzing = FakeAnalyzer(),
             settings: JobSettings = JobSettings(allowSpeechDownload: true, identifySpeakers: true,
                                                 allowSpeakerDownload: true, voicesGeneration: 7),
             limits: TranscriptionJob.Limits = .init(), engine: (any Transcribing)? = nil) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            notes = try NoteStore(root: root)
            var note = Note(id: noteID, title: "Riunione", audioFilename: "audio.m4a")
            note.duration = duration
            note.language = "it-IT"
            try await notes.save(note)
            audioURL = notes.audioURL(for: note)
            try Data(count: 4096).write(to: audioURL)
            files = CheckpointFiles(notes: notes)
            provenanceFiles = ProvenanceFiles(notes: notes)
            checkpoints = RecordingCheckpoints(files)
            transcriber = ScriptedTranscriber(script: script, total: reportsTotal ? 70 : 0, status: speechStatus)
            self.analyzer = analyzer
            host = FakeHost(settings, notes: notes)
            self.limits = limits
            self.engine = engine
        }

        func note() async -> Note? { await notes.note(noteID) }

        /// What an export would write for `note`.
        func provenance(of note: Note?) -> TranscriptProvenance? { note.flatMap(provenanceFiles.provenance(for:)) }

        func run(kind: JobKind = .transcribe, language: String = "it-IT", stop: StopSignal = StopSignal(),
                 uptime: (@Sendable () -> Int64)? = nil, availableMemory: Int64? = nil,
                 observe: @escaping @Sendable (JobEvent) -> Void = { _ in }) async -> (outcome: JobOutcome, events: [JobEvent]) {
            let ticking = FakeUptime()
            let job = TranscriptionJob(notes: notes, transcriber: engine ?? transcriber, analyzer: analyzer, checkpoints: checkpoints,
                                       provenance: provenanceFiles, host: host, clock: FakeClock(), limits: limits, budget: budget,
                                       uptimeMs: uptime ?? { ticking.next() }, availableMemory: { availableMemory })
            let record = Job(noteID: noteID, seq: 1, kind: kind, state: .running, language: language, enqueuedAt: Date())
            let events = Mutex<[JobEvent]>([])
            let outcome = await job.run(record, stop: stop) { event in
                observe(event)
                events.withLock { $0.append(event) }
            }
            return (outcome, events.withLock { $0 })
        }
    }

    /// Monotonic time that moves 10 s at every read, so every due checkpoint is also due in time.
    final class FakeUptime: Sendable {
        private let now = Mutex<Int64>(0)
        func next() -> Int64 { now.withLock { $0 += 10_000; return $0 } }
    }

    /// Monotonic time that moves only when told.
    final class ManualUptime: Sendable {
        private let now = Mutex<Int64>(0)
        var value: Int64 { now.withLock { $0 } }
        func advance(_ ms: Int64) { now.withLock { $0 += ms } }
    }

    /// Emits `script` from the request's start offset: each result whose end is after it, then its progress.
    final class ScriptedTranscriber: Transcribing, @unchecked Sendable {
        func modelName(locale: Locale) async -> String? { "Fake SpeechTranscriber \(locale.identifier(.bcp47))" }

        /// 14 results of 5 s, one word a second ("w0" at 0–0.8 s).
        static let seventySeconds: [TranscriptSegment] = (0..<14).map { index in
            let words = (0..<5).map { k in
                let second = index * 5 + k
                return TimedWord(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", 1000 + second))!,
                                 text: (k == 0 ? "" : " ") + "w\(second)", start: Double(second), end: Double(second) + 0.8)
            }
            return TranscriptSegment(id: UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!,
                                     text: words.map { $0.text.trimmingCharacters(in: .whitespaces) }.joined(separator: " "),
                                     start: Double(index * 5), end: Double(index * 5 + 5), words: words)
        }

        private let lock = NSLock()
        private let script: [TranscriptSegment]
        private let status: ModelPartStatus
        private var _starts: [TimeInterval] = []
        private var _emitted = 0
        var total: TimeInterval
        var beforeSegment: @Sendable (Int) -> Void = { _ in }
        var firstSegmentDelay: Duration?
        var hangs = false
        var downloadsFirst = false
        var volatileBeforeEachSegment = false
        /// Called while the model downloads, before any result.
        var onDownload: @Sendable () -> Void = {}
        /// Thrown in place of the result at this index.
        var failure: (index: Int, error: TranscriptionError)?
        /// The input ends before the result at this index, as if the file stopped there.
        var endsBefore: Int?

        init(script: [TranscriptSegment], total: TimeInterval, status: ModelPartStatus) {
            self.script = script; self.total = total; self.status = status
        }

        var starts: [TimeInterval] { lock.withLock { _starts } }
        var emitted: Int { lock.withLock { _emitted } }

        func transcribe(_ request: TranscriptionRequest,
                        events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
            lock.withLock { _starts.append(request.startOffset) }
            if downloadsFirst { events(.preparingModel(0.25)); onDownload() }
            if hangs { while true { try await Task.sleep(for: .seconds(60)) } }
            if let failure, failure.index < 0 { throw failure.error }
            events(.progress(done: request.startOffset, total: total))
            var out: [TranscriptSegment] = []
            for (index, segment) in script.enumerated() where segment.end > request.startOffset {
                if let failure, failure.index == index { throw failure.error }
                if let endsBefore, index >= endsBefore { break }
                if index == 0, let firstSegmentDelay { beforeSegment(index); try await Task.sleep(for: firstSegmentDelay) }
                else { beforeSegment(index) }
                try Task.checkCancellation()
                if volatileBeforeEachSegment {
                    events(.volatile(TranscriptSegment(text: "maybe", start: segment.start, end: segment.end,
                                                       words: [TimedWord(text: "maybe", start: segment.start, end: segment.end)])))
                }
                lock.withLock { _emitted += 1 }
                events(.finalized(segment))
                events(.progress(done: segment.end, total: total))
                out.append(segment)
            }
            return TranscriptionResult(segments: out)
        }

        func assetStatus(locale: Locale) async -> ModelPartStatus { status }

        func installAssets(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws { progress(1) }

        func speechLanguages() async -> [SpeechLanguage] { [] }
    }

    /// The real files, recording each checkpoint saved.
    final class RecordingCheckpoints: CheckpointStoring, @unchecked Sendable {
        private let files: CheckpointFiles
        private let lock = NSLock()
        private var _saved: [CheckpointState] = []
        var failsSaving: (any Error)?

        init(_ files: CheckpointFiles) { self.files = files }

        var saved: [CheckpointState] { lock.withLock { _saved } }

        func load(_ noteID: UUID) throws -> CheckpointState? { try files.load(noteID) }
        func save(_ state: CheckpointState, for noteID: UUID) throws {
            if let failure = lock.withLock({ failsSaving }) { throw failure }
            try files.save(state, for: noteID)
            lock.withLock { _saved.append(state) }
        }
        func discard(_ noteID: UUID) throws { try files.discard(noteID) }
        func exists(_ noteID: UUID) -> Bool { files.exists(noteID) }
        func clipsURL(for noteID: UUID) -> URL? { files.clipsURL(for: noteID) }
    }

    final class FakeHost: TranscriptionJobHost, @unchecked Sendable {
        private let lock = NSLock()
        private let settings: JobSettings
        private let notes: NoteStore
        private var _applied: [(noteID: UUID, generation: Int)] = []
        private var _analyses: [SpeakerAnalysis] = []
        var failsApplying = false

        init(_ settings: JobSettings, notes: NoteStore) { self.settings = settings; self.notes = notes }

        var applied: [(noteID: UUID, generation: Int)] { lock.withLock { _applied } }
        /// Every analysis the job gave the note, in order.
        var analyses: [SpeakerAnalysis] { lock.withLock { _analyses } }

        func jobSettings() async -> JobSettings { settings }
        func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws {
            if lock.withLock({ failsApplying }) { throw CocoaError(.fileWriteUnknown) }
            // As the app does: the streamed words with their speakers, else the words get the analysis's turns.
            _ = try await notes.mutate(noteID) { note in
                note.transcript = analysis.transcript ?? SpeakerAttribution.assign(note.transcript, turns: analysis.turns)
            }
            lock.withLock {
                _applied.append((noteID, generation))
                _analyses.append(analysis)
            }
        }
    }

    /// An analyzer whose model install fails with `failure`.
    struct InstallFailingAnalyzer: SpeakerAnalyzing {
        let failure: SpeakerAnalysisError
        func analyze(url: URL, words: [Word], allowDownload: Bool,
                     progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
            throw failure
        }
        func modelStatus() async -> ModelPartStatus { .notDownloaded }
        func refreshModelStatus() async -> ModelPartStatus { .notDownloaded }
        func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws { throw failure }
        func cancelModelInstall() async {}
        var modelInstallBytes: Int64 { 0 }
    }

    struct FailingAnalyzer: SpeakerAnalyzing {
        struct Failure: Error {}
        func analyze(url: URL, words: [Word], allowDownload: Bool,
                     progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
            throw Failure()
        }
        func modelStatus() async -> ModelPartStatus { .ready }
        func refreshModelStatus() async -> ModelPartStatus { .ready }
        func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {}
        func cancelModelInstall() async {}
        var modelInstallBytes: Int64 { 0 }
    }
}

/// What a test reads of the job's events.
extension JobEvent {
    var checkpointed: Int64? { if case .checkpointed(let doneMs) = self { doneMs } else { nil } }
    var started: JobStart? { if case .started(let start) = self { start } else { nil } }
    var isStarted: Bool { started != nil }
    var stage: TranscriptionStage? { if case .stageChanged(let stage, _, _) = self { stage } else { nil } }
}

extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen: Set<Element> = []
        return filter { seen.insert($0).inserted }
    }
}
