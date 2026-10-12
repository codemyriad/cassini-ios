#if DEBUG
import Foundation
import CassiniEngine

extension FakeAnalyzer {
    public func refreshModelStatus() async -> ModelPartStatus { await modelStatus() }

    /// Reports the install as done at once; nothing is installed, so `modelStatus` stays as it was.
    public func installModels(progress: @escaping @Sendable (Double?) -> Void) async throws { progress(1) }
}
#endif
