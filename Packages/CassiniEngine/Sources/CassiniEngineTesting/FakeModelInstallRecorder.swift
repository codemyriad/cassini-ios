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
    private let onRequest: @Sendable (ModelPart) -> Void

    public init(onRequest: @escaping @Sendable (ModelPart) -> Void = { _ in }) { self.onRequest = onRequest }
    public var snapshot: Snapshot { state.withLock { $0 } }
    func request(_ part: ModelPart) {
        state.withLock { $0.requested.append(part) }
        onRequest(part)
    }
    func complete(_ part: ModelPart) { state.withLock { $0.completed.append(part) } }
}
#endif
