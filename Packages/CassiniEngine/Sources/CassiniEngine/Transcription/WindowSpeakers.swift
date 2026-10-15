import CassiniCore
import Foundation
import CassiniNotebook

/// The speakers of a Parakeet run, told apart window by window while it decodes (Android's
/// `TranscriptionJob.onWindow` and the speaker state of its `Run`): streaming Sortformer finds the window's turns,
/// `Diarization.assign` gives each of the window's words a speaker (`<prefix><slot + 1>`, the same id in every window),
/// and the voice-clip cache keeps up to 45 s of each speaker's clean speech for its voiceprint after the decode.
///
/// - **Best effort.** Any failure but a cancellation gives that window and every later one a single voice
///   (`<prefix>1`): the windows before keep their speakers, as on Android. `onFailure` is called once.
/// - **Memory.** Before the diarizer loads, `os_proc_available_memory()` must leave `SpeakerMemory.beforeDiarizerBytes`;
///   below it the speakers fail (one voice) rather than the job.
/// - **Checkpoint.** `checkpoint()` flushes the clips to disk and returns the state to save with the window's words;
///   a run restored from it goes on with the same slots, turns, clips and prefix.
/// - **Thread.** Every call but the read-only properties after the decode runs on the inference thread, where the
///   diarizer was made. `close()` releases the native model there.
public final class WindowSpeakers: @unchecked Sendable {
    public let prefix: String
    private let engines: any SpeakerEngines
    private let clips: (any ClipStore)?
    private let cache: VoiceClipCache?
    private let availableMemory: @Sendable () -> Int64?
    private let onFailure: @Sendable () -> Void
    private let lock = NSLock()
    private var diarizer: (any StreamingDiarizer)?
    private var restored: DiarizerState?
    private var failure = false

    /// `clips` keeps the voice clips (nil: no voiceprint model, so none are kept). `restored` is the checkpoint's
    /// speaker state; its clips must be in `clips`.
    public init(engines: any SpeakerEngines, clips: (any ClipStore)?, restored: SpeakerCheckpoint? = nil,
                prefix: String = WindowSpeakers.freshPrefix(),
                availableMemory: @escaping @Sendable () -> Int64? = { nil },
                onFailure: @escaping @Sendable () -> Void = {}) throws(VoiceClipCache.Invalid) {
        self.engines = engines
        self.clips = clips
        self.prefix = restored?.prefix ?? prefix
        self.availableMemory = availableMemory
        self.onFailure = onFailure
        self.restored = restored?.diarizer
        failure = restored?.failed ?? false
        if let clips { cache = try VoiceClipCache(audio: clips, restored: restored?.voiceClips) } else { cache = nil }
    }

    /// The prefix of a fresh run's speaker ids: a UUID and `_`, so every run has speakers no other run has (Android's
    /// `diar_<uuid>_`; iOS's form fits the 40 characters `TranscriptBudget` counts per id).
    public static func freshPrefix() -> String { UUID().uuidString + "_" }

    /// Whether the speakers failed in this run or a run before it.
    public var failed: Bool { lock.withLock { failure } }

    /// Every turn so far, on the recording clock: the diarizer's, or the restored ones before it opens.
    public var turns: [DiarizerTurn] { lock.withLock { diarizer?.turns ?? restored?.turns ?? [] } }

    /// Milliseconds spent in native diarization over every run.
    public var elapsedMs: Int64 { lock.withLock { diarizer?.elapsedMs ?? restored?.elapsedMs ?? 0 } }

    /// The voice clips of each speaker, in samples of `clips`.
    public var clipWindows: [String: [PrintWindow]] { lock.withLock { cache?.windows ?? [:] } }

    /// The clips' audio, for the voiceprints after the decode.
    public var clipAudio: (any ClipStore)? { clips }

    /// The words of one window that starts at `startMs`, on the window's clock, with their speakers.
    public func window(_ audio: PcmAudio, startMs: Int64, words: Transcript) throws -> Transcript {
        try lock.withLock {
            if failure { return oneVoice(words) }
            do {
                let diarizer = try open()
                let found = try diarizer.process(audio, startMs: startMs)
                let assigned = found.isEmpty ? oneVoice(words).words
                    : Diarization.assign(words.words, turns: found, prefix: prefix, stableIds: true)
                try cache?.accept(audio, turns: found, words: assigned, startMs: startMs)
                return Transcript(assigned, language: words.language)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = true
                onFailure()
                return oneVoice(words)
            }
        }
    }

    /// The checkpoint of the speakers so far, with the clips flushed to disk first. A flush that fails counts as a
    /// speaker failure: the clips are not counted on.
    public func checkpoint() -> SpeakerCheckpoint {
        lock.withLock {
            if let clips = clips as? ClipFile, (try? clips.sync()) == nil, !failure {
                failure = true
                onFailure()
            }
            return SpeakerCheckpoint(prefix: prefix, failed: failure, diarizer: diarizer?.state ?? restored,
                                     clipSamples: clips?.sampleCount ?? 0, voiceClips: cache?.windows ?? [:])
        }
    }

    /// Releases the native diarizer; its turns and time stay readable.
    public func close() {
        lock.withLock {
            guard let diarizer else { return }
            restored = diarizer.state
            self.diarizer = nil
        }
    }

    private func open() throws -> any StreamingDiarizer {
        if let diarizer { return diarizer }
        guard SpeakerMemory.allows(availableBytes: availableMemory(), SpeakerMemory.beforeDiarizerBytes) else {
            throw JobFailure.memory
        }
        let opened = try engines.openDiarizer(restored: restored)
        diarizer = opened
        return opened
    }

    private func oneVoice(_ words: Transcript) -> Transcript {
        Transcript(words.words.map { Word("\(prefix)1", $0.startMs, $0.endMs, $0.text) }, language: words.language)
    }
}

/// The memory the speaker models need (iOS only, as `ParakeetMemory`): below it the speakers fail, the words go on.
/// **Provisional until the device gate**, from the simulator (scripts/speaker-smoke.sh): the diarizer and its cache
/// hold about 250 MiB, a CAM++ print about 100 MiB.
public enum SpeakerMemory {
    public static let beforeDiarizerBytes: Int64 = 400 << 20
    public static let beforePrintsBytes: Int64 = 200 << 20

    /// Whether `availableBytes` leaves `needed`; nil (the system does not tell, as on a Mac or the simulator) always
    /// does.
    public static func allows(availableBytes: Int64?, _ needed: Int64) -> Bool {
        guard let availableBytes, availableBytes > 0 else { return true }
        return availableBytes >= needed
    }
}
