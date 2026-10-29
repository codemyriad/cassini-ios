#if DEBUG
import CassiniCore
import Foundation
import Synchronization
import CassiniEngine
import CassiniNotebook

/// A speaker analyzer that returns a fixed analysis, optionally after the test lets it go. With `engines` a Parakeet
/// run streams its speakers through them.
public final class FakeAnalyzer: SpeakerAnalyzing {
    private let analysis: SpeakerAnalysis
    private let identity: String?
    private let engines: (any SpeakerEngines)?
    private let prints: Bool
    private let gate: Mutex<[CheckedContinuation<Void, Never>]?>
    private let calls = Mutex(0)
    private let given = Mutex<[[Word]]>([])

    /// With `suspends`, every analysis waits for `resume()`. `modelIdentity` nil stands for missing models.
    public init(analysis: SpeakerAnalysis = SpeakerAnalysis(turns: [], prints: []), modelIdentity: String? = "fake-model",
                suspends: Bool = false, engines: (any SpeakerEngines)? = nil, printsReady: Bool = true) {
        self.analysis = analysis
        identity = modelIdentity
        self.engines = engines
        prints = printsReady
        gate = Mutex(suspends ? [] : nil)
    }

    public var analyzeCount: Int { calls.withLock { $0 } }
    /// The words each whole-file analysis was given.
    public var analyzedWords: [[Word]] { given.withLock { $0 } }

    public func analyze(url: URL, words: [Word], allowDownload: Bool,
                        progress: @escaping @Sendable (SpeakerAnalysisEvent) -> Void) async throws -> SpeakerAnalysis {
        calls.withLock { $0 += 1 }
        given.withLock { $0.append(words) }
        progress(.analyzing(0))
        await withCheckedContinuation { continuation in
            let waits = gate.withLock { waiters in
                guard waiters != nil else { return false }
                waiters?.append(continuation)
                return true
            }
            if !waits { continuation.resume() }
        }
        try Task.checkCancellation()
        progress(.analyzing(1))
        return analysis
    }

    /// Lets every waiting analysis finish, and the next ones run straight through.
    public func resume() {
        let waiting = gate.withLock { waiters in defer { waiters = nil }; return waiters ?? [] }
        for continuation in waiting { continuation.resume() }
    }

    public func streamingEngines() async -> (any SpeakerEngines)? { identity == nil ? nil : engines }
    public func printsReady() async -> Bool { identity != nil && prints }
    public func modelStatus() async -> ModelPartStatus { identity == nil ? .notDownloaded : .ready }
}

/// Speaker engines whose diarizer finds what `turns` says for each window (on the window's clock) and whose prints are
/// `vector` for each speaker, with the seconds of its clips. `failAt` makes the diarizer throw from that window's start
/// on. Every call runs on the caller's thread.
public final class FakeSpeakerEngines: SpeakerEngines, @unchecked Sendable {
    public typealias Turns = @Sendable (_ startMs: Int64, _ durationMs: Int64) -> [DiarizerTurn]
    public struct Failure: Error {}

    private let turns: Turns
    private let vector: @Sendable (String) -> [Float]
    private let failAt: Int64?
    private let lock = NSLock()
    private var restores: [DiarizerState?] = []
    private var printCalls: [[String: [PrintWindow]]] = []

    public init(failAt: Int64? = nil, vector: @escaping @Sendable (String) -> [Float] = FakeSpeakerEngines.unitPrint,
                turns: @escaping Turns) {
        self.turns = turns; self.vector = vector; self.failAt = failAt
    }

    /// A 512-value print of one speaker: a unit vector along an axis chosen by its id.
    @Sendable public static func unitPrint(_ speaker: String) -> [Float] {
        var vector = [Float](repeating: 0, count: VoiceprintModel.dimension)
        let axis = speaker.unicodeScalars.reduce(0) { ($0 * 31 + Int($1.value)) % VoiceprintModel.dimension }
        vector[axis] = 1
        return vector
    }

    /// The state each diarizer was opened with, in order.
    public var opened: [DiarizerState?] { lock.withLock { restores } }
    /// The windows each prints call was asked for.
    public var printRequests: [[String: [PrintWindow]]] { lock.withLock { printCalls } }

    public func openDiarizer(restored: DiarizerState?) throws -> any StreamingDiarizer {
        lock.withLock { restores.append(restored) }
        return FakeDiarizer(restored: restored, turns: turns, failAt: failAt)
    }

    public func prints(_ audio: any PcmSource, windows: [String: [PrintWindow]],
                       active: () throws -> Void) throws -> [String: Voiceprint] {
        lock.withLock { printCalls.append(windows) }
        try active()
        return windows.mapValues { spans in
            let samples = spans.reduce(0) { $0 + $1.endSample - $1.startSample }
            return Voiceprint(vector: [], seconds: Double(samples) / Double(audio.sampleRate))
        }.reduce(into: [:]) { result, entry in
            result[entry.key] = Voiceprint(vector: vector(entry.key), seconds: entry.value.seconds)
        }
    }

    public func run<Value: Sendable>(_ body: @escaping @Sendable () throws -> Value) async throws -> Value { try body() }
}

/// The diarizer of `FakeSpeakerEngines`: its turns go through `TurnHistory` as the real one's do, and its state's
/// cache counts the windows it saw.
public final class FakeDiarizer: StreamingDiarizer {
    private var history: TurnHistory
    private let turnsOf: FakeSpeakerEngines.Turns
    private let failAt: Int64?
    private var windows: Int
    public private(set) var elapsedMs: Int64

    init(restored: DiarizerState?, turns: @escaping FakeSpeakerEngines.Turns, failAt: Int64?) {
        history = TurnHistory(restored?.turns ?? [])
        turnsOf = turns
        self.failAt = failAt
        windows = Int(restored?.cache.first ?? 0)
        elapsedMs = restored?.elapsedMs ?? 0
    }

    public var turns: [DiarizerTurn] { history.turns }

    public func process(_ audio: PcmAudio, startMs: Int64) throws -> [DiarizerTurn] {
        if let failAt, startMs >= failAt { throw FakeSpeakerEngines.Failure() }
        let found = turnsOf(startMs, audio.durationMs)
        windows += 1
        elapsedMs += 5
        history.add(found, startMs: startMs)
        return found
    }

    public var state: DiarizerState { DiarizerState(cache: [Float(windows)], elapsedMs: elapsedMs, turns: history.turns) }
}
#endif
