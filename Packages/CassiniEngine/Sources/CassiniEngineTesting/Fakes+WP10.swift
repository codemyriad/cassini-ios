#if DEBUG
import Foundation
import CassiniEngine

extension FakeAnalyzer {
    public func refreshModelStatus() async -> ModelPartStatus { await modelStatus() }

    /// Reports the install as done at once; nothing is installed, so `modelStatus` stays as it was.
    public func installModels(progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
        installRecorder?.request(.speakers)
        progress(.downloading(1))
        installRecorder?.complete(.speakers)
    }

    /// About what the real speaker models ask for.
    public var modelInstallBytes: Int64 { 54_000_000 }
}

extension FakeTranscriber {
    /// The fake's one language, installed when its assets are ready.
    public func speechLanguages() async -> [SpeechLanguage] { [SpeechLanguage(id: "en-US", installed: status == .ready)] }
}
#endif
