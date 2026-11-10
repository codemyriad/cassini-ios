import Foundation
import os

/// Release diagnostics for public, pinned model artifacts. Call before wrapping an error: descriptions and userInfo
/// can contain container paths or request URLs, so only stable error codes and caller-owned stage names are logged.
enum ModelInstallDiagnostics {
    private static let log = Logger(subsystem: "io.codemyriad.cassini", category: "ModelInstall")

    static func begin(model: String, stage: String) {
        log.notice("model=\(model, privacy: .public) stage=\(stage, privacy: .public) begin")
    }

    /// `model` is a catalog ID or pinned artifact name, never a file path; `stage` is a fixed diagnostic label.
    static func failure(model: String, stage: String, error: any Error) {
        guard !ModelInstaller.isCancellation(error) else { return }
        let native = error as NSError
        let failure = (error as? ModelError)?.failure.code ?? "none"
        log.error("model=\(model, privacy: .public) stage=\(stage, privacy: .public) errorDomain=\(native.domain, privacy: .public) errorCode=\(native.code, privacy: .public) failure=\(failure, privacy: .public)")
    }
}
