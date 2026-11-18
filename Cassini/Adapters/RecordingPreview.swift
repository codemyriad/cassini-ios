import Foundation
import Synchronization
import CassiniCore
import CassiniInference

/// A recording's optional, in-memory draft. A view can query the latest snapshot without owning decode.
final class RecordingPreview: Sendable {
    typealias Run = @Sendable (URL, AsyncStream<Void>, LiveCAFTranscription.Events) async throws -> Void

    struct Snapshot: Sendable {
        var words: [Word] = []
        var settledMs: Int64 = 0
        var needsSavedAudio = false
    }

    private let state: Mutex<Snapshot>
    private let wake: AsyncStream<Void>.Continuation
    let task: Task<Void, Never>

    init(url: URL, run: @escaping Run) {
        let (stream, continuation) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wake = continuation
        let state = Mutex(Snapshot())
        self.state = state
        task = Task.detached(priority: .utility) {
            do {
                try await run(url, stream) { event in
                    state.withLock { draft in
                        switch event {
                        case .skipped:
                            draft.needsSavedAudio = true
                        case let .revision(from, through, settled, words):
                            draft.words.removeAll { word in
                                let midpoint = word.startMs + (word.endMs - word.startMs) / 2
                                return from <= midpoint && midpoint <= through
                            }
                            draft.words.append(contentsOf: words)
                            draft.settledMs = max(draft.settledMs, settled)
                        }
                    }
                }
            } catch {
                state.withLock { $0.needsSavedAudio = true }
            }
        }
    }

    var snapshot: Snapshot { state.withLock { $0 } }
    func audioAvailable() { wake.yield() }
    func finish() { wake.finish() }
    func cancel() { task.cancel(); wake.finish() }
}
