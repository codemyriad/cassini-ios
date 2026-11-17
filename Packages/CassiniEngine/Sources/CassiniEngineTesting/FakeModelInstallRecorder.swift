#if DEBUG
import Foundation
import Synchronization
import CassiniNotebook

/// A shared journal of actual calls into the fake speech and paired speaker installers.
/// Recording consent or constructing a plan never writes this journal.
public final class FakeModelInstallRecorder: Sendable {
    public struct Snapshot: Sendable {
        public var requested: [ModelPart] = []
        public var completed: [ModelPart] = []
    }
    private let state = Mutex(Snapshot())
    public let holdDownload: Bool
    private let onRequest: @Sendable (ModelPart) -> Void

    public init(holdDownload: Bool = false, onRequest: @escaping @Sendable (ModelPart) -> Void = { _ in }) {
        self.holdDownload = holdDownload; self.onRequest = onRequest
    }

    /// An event gate for testing progress and Cancel; it ends only when the installer task is cancelled.
    func waitIfHeld() async throws {
        guard holdDownload else { return }
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        defer { continuation.finish() }
        for await _ in stream {}
        try Task.checkCancellation()
    }
    public var snapshot: Snapshot { state.withLock { $0 } }
    func request(_ part: ModelPart) {
        state.withLock { $0.requested.append(part) }
        onRequest(part)
    }
    func complete(_ part: ModelPart) { state.withLock { $0.completed.append(part) } }
}
#endif
