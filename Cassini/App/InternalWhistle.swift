import Foundation
import os
import Synchronization
import CassiniNotebook
import CassiniEngine
import CassiniInference
import CassiniWhistle

/// Regular Release/App Store builds never consult the experimental preference. Internal archives must export
/// with testFlightInternalTestingOnly=true; the selected backend is frozen until the next app launch.
enum InternalWhistle {
    private static let jobMeasurement = Mutex<WhistleMemoryMonitor?>(nil)
    static let preference = "cassini.internal.whistleEnabled"
    static var isInternalBuild: Bool {
        #if CASSINI_INTERNAL_TESTFLIGHT
        true
        #else
        false
        #endif
    }
    private static var reportURL: URL {
        URL.applicationSupportDirectory.appendingPathComponent("InternalDiagnostics/whistle-memory-latest.json")
    }
    static var diagnostics: TranscriptionJob.Diagnostics? {
        guard isInternalBuild else { return nil }
        return .init(started: { job in
            guard job.recognizer == SpeechRecognizer.whistle.rawValue else { return }
            jobMeasurement.withLock { $0 = WhistleMemoryMonitor() }
        }, finished: { job, outcome in
            guard job.recognizer == SpeechRecognizer.whistle.rawValue,
                  let measurement = jobMeasurement.withLock({ value in defer { value = nil }; return value }) else { return }
            let previous = (try? Data(contentsOf: reportURL)).flatMap { try? JSONDecoder().decode(WhistleMemoryReport.self, from: $0) }
            let succeeded: Bool
            if case .done = outcome { succeeded = true } else { succeeded = false }
            var report = measurement.finish(succeeded: succeeded,
                nativeModelReleased: previous?.nativeModelReleased ?? false, scope: "whole-job")
            report.jobKind = job.kind.rawValue
            writeReport(report)
        })
    }
    static func writeReport(_ report: WhistleMemoryReport) {
        guard isInternalBuild else { return }
        do {
            try FileManager.default.createDirectory(at: reportURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let bytes = try encoder.encode(report)
            try bytes.write(to: reportURL, options: .atomic)
            if ProcessInfo.processInfo.arguments.contains("--internal-whistle-lab") {
                let compact = try JSONEncoder().encode(report)
                print("CASSINI_WHISTLE_MEMORY " + String(decoding: compact, as: UTF8.self))
            }
        } catch { /* A diagnostic write never changes the job outcome or a recording. */ }
    }
    static func capability() -> WhistleCapability {
        #if arch(arm64)
        let arm64 = true
        #else
        let arm64 = false
        #endif
        let available = os_proc_available_memory()
        return .experiment(internalBuild: isInternalBuild, optedIn: true, arm64: arm64,
            osSupported: ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            availableMemory: available > 0 ? UInt64(available) : nil,
            bundleVerified: WhistleRuntime.bundleIsVerified())
    }
    static func route(_ legacy: any Transcribing, defaults: UserDefaults) -> any Transcribing {
        guard isInternalBuild else { return legacy }
        let whistle = WhistleTranscriber(acceptance: capability(), memoryReport: writeReport)
        return RoutedTranscriber(legacy: legacy,
            preferred: defaults.bool(forKey: preference) ? whistle : nil, retained: whistle)
    }
}
