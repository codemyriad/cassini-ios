import AVFoundation
import CassiniCore
import CassiniEngine
import CassiniNotebook

/// Parakeet Ultra over the native runtime (`SpeechRuntime`, CassiniSherpa's in the app): the recording read as 16 kHz
/// mono floats, cut into 28 s windows by `IncrementalTranscript`, each window decoded by `ParakeetDecode` with SPEECH
/// cutting when the speech detector is installed and QUIET cutting otherwise (Android's `IncrementalRecognizer`).
///
/// - **Models.** Before it decodes, a run asks the installer for what `ParakeetModels.request` says: Ultra when it is
///   missing (only with `allowDownload`, else `needsConsent`; a failed install is `DOWNLOAD_*`), or the detector alone
///   when only it is missing and the device is online (best effort). Before any native object is made, Ultra's files
///   must have their pinned sizes and its marker (`ModelCatalog.parakeet.ready`), else `MODEL`.
/// - **Thread.** Reading and decoding run on one dedicated thread (`InferenceThread.speech`). The recognizer is made
///   with the first window and released when the run ends, before the speaker step loads its own models.
/// - **Memory.** `os_proc_available_memory()` is checked before the model loads and before each window
///   (`ParakeetMemory`); below the figure the run fails with `MEMORY` rather than be ended by iOS.
/// - **Events.** `.preparingModel` only while a model downloads; `.window` after each window, with every word so far
///   and where to go on from; `.progress` with the decoded audio.
/// - **Resume.** A run with `TranscriptRequest.resume` reads the file from its start again, keeps the samples of the
///   checkpoint's window and goes on from there, so it decodes what an uninterrupted run would (Android keeps the
///   window's samples in the checkpoint instead).
/// - **Stop.** Cancelling the task stops before the next native call; the call in flight finishes first.
public struct ParakeetTranscriber: Transcribing {
    /// Where the models are and how missing ones are installed.
    public struct Models: Sendable {
        public typealias Install = @Sendable (Set<ModelPart>, @escaping @Sendable (DownloadProgress) -> Void) async throws
            -> InstallOutcome
        public var root: URL
        /// Whether the device has a network path now.
        public var online: @Sendable () -> Bool
        /// The shared installer (`PinnedModelInstaller.install`); nil when this build installs nothing itself.
        public var install: Install?

        public init(root: URL, online: @escaping @Sendable () -> Bool = { false }, install: Install? = nil) {
            self.root = root; self.online = online; self.install = install
        }

        var speechReady: Bool { ModelCatalog.parakeet.ready(in: root) }
        var detectorReady: Bool { ModelCatalog.vad.ready(in: root) }
        var detector: URL { URL(fileURLWithPath: ModelCatalog.vad.path(in: root, ModelCatalog.sileroVad.name)) }
    }

    private let models: Models
    private let runtime: SpeechRuntime
    private let availableMemory: @Sendable () -> Int64?
    private let thread: InferenceThread

    public init(models: Models, runtime: SpeechRuntime,
                availableMemory: @escaping @Sendable () -> Int64? = TranscriptionJob.availableMemory) {
        self.init(models: models, runtime: runtime, availableMemory: availableMemory, thread: .speech)
    }

    init(models: Models, runtime: SpeechRuntime, availableMemory: @escaping @Sendable () -> Int64?,
         thread: InferenceThread) {
        self.models = models; self.runtime = runtime; self.availableMemory = availableMemory; self.thread = thread
    }

    public var recognizer: SpeechRecognizer { .parakeet }

    public func segmentation() async -> String? {
        DecodeCutting.incrementalProvenance(detectorReady: models.detectorReady)
    }

    /// Parakeet takes no language: the one model hears all of its 25.
    public func assetStatus(locale: Locale) async -> ModelPartStatus { models.speechReady ? .ready : .notDownloaded }

    public func speechLanguages() async -> [SpeechLanguage] { [] }

    public func installAssets(locale: Locale, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard !models.speechReady, models.install != nil else { return }
        try await install { if let fraction = $0 { progress(fraction) } }
    }

    public func transcribe(_ request: TranscriptionRequest,
                           events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
        try await prepareModels(allowDownload: request.allowDownload, events: events)
        try Task.checkCancellation()
        // The native loader ends the process on a missing file: sizes and the marker are checked first.
        let files = ParakeetFiles(root: models.root)
        guard models.speechReady, files.present() else { throw TranscriptionError.failed(.model) }
        let run = Run(files: files, detector: models.detectorReady ? models.detector : nil, runtime: runtime,
                      availableMemory: availableMemory)
        let cancel = CancelFlag()
        return try await withTaskCancellationHandler {
            try await thread.run { try run.transcribe(request, cancel: cancel, events: events) }
        } onCancel: {
            cancel.set()
        }
    }

    // MARK: - Models

    private func prepareModels(allowDownload: Bool,
                               events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws {
        let speechReady = models.speechReady
        let parts = ParakeetModels.request(speechReady: speechReady, detectorReady: models.detectorReady,
                                           online: models.online())
        guard !parts.isEmpty else { return }
        if speechReady {
            // The detector alone, best effort: without it the run cuts at quiet points.
            guard models.install != nil else { return }
            do { try await install { events(.preparingModel($0)) } } catch is CancellationError {
                throw CancellationError()
            } catch {}
            return
        }
        guard allowDownload else { throw TranscriptionError.needsConsent }
        guard models.install != nil else { throw TranscriptionError.failed(.model) }
        events(.preparingModel(nil))
        try await install { events(.preparingModel($0)) }
    }

    /// Installs SPEECH, reporting the fraction done (nil while unknown).
    private func install(_ report: @escaping @Sendable (Double?) -> Void) async throws {
        guard let install = models.install else { return }
        let outcome = try await install([.speech]) { progress in
            report(progress.totalBytes > 0 ? Double(progress.doneBytes) / Double(progress.totalBytes) : nil)
        }
        switch outcome {
        case .installed: return
        case .failed(_, let error, _): throw TranscriptionError.failed(.download(error))
        case .needsConsent: throw TranscriptionError.needsConsent
        }
    }
}

// MARK: - One run

extension ParakeetTranscriber {
    /// One run on the inference thread. Its native objects live inside `transcribe` and go when it returns.
    struct Run: Sendable {
        let files: ParakeetFiles
        let detector: URL?
        let runtime: SpeechRuntime
        let availableMemory: @Sendable () -> Int64?

        static let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(Limits.asrRate), channels: 1,
                                          interleaved: false)!

        func transcribe(_ request: TranscriptionRequest, cancel: CancelFlag,
                        events: @Sendable (TranscriptionEvent) -> Void) throws -> TranscriptionResult {
            let reader: FileReader
            do { reader = try FileReader(url: request.url, from: 0, to: Self.format, downmix: true) } catch {
                throw TranscriptionError.failed(.open)
            }
            let total = reader.duration
            let resume = request.resume
            // The diarizer lives on this thread with the recognizer and goes with it (Android releases both when the
            // decode ends); its turns and clips stay for the voiceprints.
            let speakers = request.speakers
            defer { speakers?.close() }
            if let resume, !resume.recognition.valid { throw TranscriptionError.failed(.checkpointMismatch) }
            events(.progress(done: TimeInterval(resume?.recognition.doneMs ?? 0) / 1000, total: total))

            // A detector that cannot be made leaves the run on quiet points.
            let speech: (any SpeechDetecting)? = detector.flatMap { try? runtime.makeDetector(SileroConfig(model: $0)) }
            var decoder: SpeechWordDecoder?
            // Android's `IncrementalRecognizer.inferenceMs`: each window's decode once the recognizer is loaded (the
            // speech detector, the decoder calls and the word gate), not the reading or the model load.
            var inferenceNanoseconds: UInt64 = 0
            // What the detector hears (D26.1): the track high-passed once in reading order, so the filter runs on
            // across windows and their overlap. A resumed run's track starts at its restored window.
            var input: SpeechInput?
            let recognize = { (audio: PcmAudio, startMs: Int64) throws -> Transcript in
                try cancel.check()
                guard ParakeetMemory.allows(availableBytes: availableMemory(), loaded: decoder != nil) else {
                    throw JobFailure.memory
                }
                if decoder == nil {
                    do { decoder = SpeechWordDecoder(try runtime.makeDecoder(ParakeetConfig(files)), cancelled: { cancel.isSet }) } catch {
                        throw JobFailure.model
                    }
                }
                let began = DispatchTime.now().uptimeNanoseconds
                let start = startMs * Int64(Limits.asrRate) / 1000
                let detectorInput = speech.map { _ in Self.detectorInput(input, from: start, audio) }
                let decoded = try ParakeetDecode.transcribe(audio, decoder: decoder!, detector: speech,
                                                            detectorInput: detectorInput, policy: .wholeSpans,
                                                            cutting: DecodeCutting.cutting(detectorReady: speech != nil))
                inferenceNanoseconds += DispatchTime.now().uptimeNanoseconds - began
                // The next window starts at this one's overlap.
                input?.discard(before: start + Int64(audio.samples.count - IncrementalTranscript.overlapSamples))
                let words = Transcript(decoded.words.map { Word("", $0.startMs, $0.endMs, $0.text) })
                // Android's `onChunk`: the window's speakers, outside the decode time. Without them the words have no
                // speaker id.
                try cancel.check()
                return try speakers?.window(audio, startMs: startMs, words: words) { try cancel.check() } ?? words
            }
            func decodeMs() -> Int64 { Int64(inferenceNanoseconds / 1_000_000) }

            var transcript: IncrementalTranscript?
            // Samples read so far at 16 kHz, and the window of a resumed run, collected while its start is read again.
            var position: Int64 = 0
            var window: [Float] = []
            if speech != nil { input = SpeechInput(start: resume?.recognition.start ?? 0) }
            if resume == nil { transcript = try IncrementalTranscript(recognize: recognize) }
            var reportedMs = resume?.recognition.doneMs ?? 0
            while let (buffer, _) = reader.nextBuffer() {
                try cancel.check()
                let count = Int(buffer.frameLength)
                let samples = Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: count))
                var offset = 0
                if transcript == nil, let resume {
                    // Until the checkpoint's position: keep what its window holds, decode nothing.
                    let need = Int(min(Int64(count), resume.recognition.position - position))
                    let windowStart = Int(max(0, resume.recognition.start - position))
                    if windowStart < need { window.append(contentsOf: samples[windowStart..<need]) }
                    position += Int64(need)
                    offset = need
                    guard position == resume.recognition.position else { continue }
                    input?.append(window)
                    transcript = try restored(resume, window, recognize)
                }
                guard let transcript, offset < count else { continue }
                let rest = offset == 0 ? samples : Array(samples[offset...])
                input?.append(rest)
                try transcript.accept(rest, count: rest.count)
                position += Int64(rest.count)
                if transcript.doneMs > reportedMs {
                    reportedMs = transcript.doneMs
                    let state = transcript.checkpoint()
                    events(.window(TranscriptWindow(words: state.words, recognition: RecognitionCheckpoint(state),
                                                    inferenceMs: decodeMs(), speakers: speakers?.checkpoint())))
                    events(.progress(done: TimeInterval(reportedMs) / 1000, total: total))
                }
            }
            try cancel.check()
            // A read error ends the input early: what came before it is not the whole file.
            guard reader.failure == nil, reader.reachedEnd else { throw TranscriptionError.failed(.open) }
            if transcript == nil, let resume {
                // The file ended exactly at the checkpoint's position.
                guard position == resume.recognition.position else { throw TranscriptionError.failed(.open) }
                input?.append(window)
                transcript = try restored(resume, window, recognize)
            }
            guard let transcript else { throw TranscriptionError.failed(.open) }
            let words = try transcript.finish().words
            events(.progress(done: total, total: total))
            return TranscriptionResult(segments: TranscriptSegment.segments(of: words),
                                       segmentation: DecodeCutting.incrementalProvenance(detectorReady: speech != nil),
                                       inferenceMs: decodeMs(), speakers: speakers?.checkpoint())
        }

        /// The detector's input for the window of `audio` at `start`: the track's filtered samples, which it always
        /// holds; a window it does not hold is filtered on its own from zero state.
        static func detectorInput(_ input: SpeechInput?, from start: Int64, _ audio: PcmAudio) -> [Float] {
            if let held = input?.window(from: start, count: audio.samples.count) { return held }
            var filter = SpeechInputFilter()
            return filter(audio.samples)
        }

        private func restored(_ resume: TranscriptResume, _ window: [Float],
                              _ recognize: @escaping (PcmAudio, Int64) throws -> Transcript) throws -> IncrementalTranscript {
            do {
                return try IncrementalTranscript(restored: resume.recognition.state(window: window, words: resume.words),
                                                 recognize: recognize)
            } catch {
                throw TranscriptionError.failed(.checkpointMismatch)
            }
        }
    }
}
