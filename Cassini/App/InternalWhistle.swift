import Foundation
import Darwin
import AVFoundation
import os
import Synchronization
import CassiniNotebook
import CassiniEngine
import CassiniInference
import CassiniWhistle

/// Internal-only memory diagnostics and isolated lab support. D78's normal model selection lives in
/// SpeechModelsStore and does not depend on this flag or on a receipt. Internal archives export internal-only.
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
                fflush(nil)
            }
        } catch { /* A diagnostic write never changes the job outcome or a recording. */ }
    }
    /// Public English fixture only: longest permitted ASR input, repeated with the VAD session resident.
    /// Cancellation is requested synchronously at the model-ready event, without sleeps or a scheduling race.
    static func runLabSoak() async {
        guard isInternalBuild, ProcessInfo.processInfo.arguments.contains("--internal-whistle-lab-soak") else { return }
        do {
            try await NativeBudget.shared.withBudget {
                let measurement = WhistleMemoryMonitor()
                var released = false
                do {
                    let acceptance = capability()
                    guard acceptance.available,
                          let resources = Bundle.main.resourceURL else { throw WhistleError.unavailable }
                    let file = try AVAudioFile(forReading: resources.appendingPathComponent("WhistleTests/jfk.wav"))
                    guard file.processingFormat.sampleRate == 16000, file.processingFormat.channelCount == 1,
                          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)) else {
                        throw WhistleError.invalidInput
                    }
                    try file.read(into: buffer)
                    guard let pointer = buffer.floatChannelData?.pointee, buffer.frameLength > 0 else { throw WhistleError.invalidInput }
                    let source = Array(UnsafeBufferPointer(start: pointer, count: Int(buffer.frameLength)))
                    let pcm = (0..<240128).map { source[$0 % source.count] }
                    let vad = try WhistleVAD(model: resources.appendingPathComponent("Whistle/silero-vad-6.2.1.onnx"))
                    var first: WhistleResult?
                    for _ in 0..<10 {
                        try Task.checkCancellation()
                        _ = try vad.probability(Array(pcm.prefix(512)))
                        let result = try await WhistleRuntime.shared.transcribe(pcm, acceptance: acceptance)
                        guard !result.words.isEmpty, result.language == "en" else { throw WhistleError.invalidOutput }
                        if let first { guard result == first else { throw WhistleError.invalidOutput } }
                        else { first = result }
                        released = await WhistleRuntime.shared.close()
                    }
                    // Keep the recurrent VAD allocation alive through every largest-window decode.
                    _ = try vad.probability(Array(pcm.suffix(512)))
                    let cancelled = Task {
                        try await WhistleTranscriber(acceptance: acceptance).transcribe(
                            .init(url: resources.appendingPathComponent("WhistleTests/jfk.wav"), language: "", allowDownload: false)) {
                                if case .progress(let done, _) = $0, done == 0 {
                                    withUnsafeCurrentTask { $0?.cancel() }
                                }
                            }
                    }
                    do { _ = try await cancelled.value; throw WhistleError.nativeFailure }
                    catch is CancellationError { }
                    var report = measurement.finish(succeeded: true, nativeModelReleased: released, scope: "maximum-window-soak")
                    report.completedWindows = 10; report.samplesPerWindow = 240128; report.cancelledAtModelReady = true
                    writeReport(report)
                } catch {
                    released = await WhistleRuntime.shared.close()
                    writeReport(measurement.finish(succeeded: false, nativeModelReleased: released, scope: "maximum-window-soak"))
                    print("CASSINI_WHISTLE_LAB_ERROR " + String(describing: error)); fflush(nil)
                }
            }
        } catch { print("CASSINI_WHISTLE_LAB_ERROR " + String(describing: error)); fflush(nil) }
    }
    static func capability() -> WhistleCapability {
        #if arch(arm64)
        let arm64 = true
        #else
        let arm64 = false
        #endif
        let available = os_proc_available_memory()
        return .experiment(internalBuild: isInternalBuild, optedIn: true, arm64: arm64,
            osSupported: LivePlatform.whistleOperatingSystemSupported, cpuSupported: LivePlatform.whistleCPUSupported,
            physicalMemory: ProcessInfo.processInfo.physicalMemory,
            availableMemory: available > 0 ? UInt64(available) : nil,
            bundleVerified: WhistleRuntime.cachedBundleVerification() == true)
    }
    static func route(_ legacy: any Transcribing, defaults: UserDefaults) -> any Transcribing {
        guard isInternalBuild else { return legacy }
        let whistle = WhistleTranscriber(acceptance: capability(), memoryReport: writeReport)
        return RoutedTranscriber(legacy: legacy,
            preferred: defaults.bool(forKey: preference) ? whistle : nil, retained: whistle)
    }
}
