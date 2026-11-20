import AVFoundation
import CassiniAudio
import CassiniCore
import CassiniEngine
import CassiniEngineTesting
import CassiniInference
import CassiniNotebook
import CassiniSherpa
import CassiniWhistle
import CryptoKit
import Darwin
import Foundation
import Synchronization
import UIKit
import XCTest
@testable import Cassini

/// Physical handset qualification suite for `D-1126` (`D-1117` head-start transcription):
/// - `testQualificationHarnessAndTelemetryContract` always runs on simulator & CI (fast, deterministic, zero sleeps).
/// - `test01...` through `test04...` are opt-in physical-handset qualification tests gated on either
///   `CassiniHandsetQual.json` inside the test bundle (injected by `scripts/devicefarm-qualify.py`) or
///   `CASSINI_HANDSET_QUAL=1` in the environment.
final class HandsetQualificationTests: XCTestCase {

    // MARK: - Configuration

    struct QualConfig: Codable, Sendable {
        var shortSeconds: Int = 300
        var longSeconds: Int = 1800
        var runParakeet: Bool = true
        var runWhistle: Bool = true
        var runLongParakeet: Bool = true
        var runLongWhistle: Bool = false

        static func load() -> QualConfig? {
            if let url = Bundle(for: HandsetQualificationTests.self).url(forResource: "CassiniHandsetQual", withExtension: "json"),
               let data = try? Data(contentsOf: url),
               let decoded = try? JSONDecoder().decode(QualConfig.self, from: data) {
                return decoded
            }
            let env = ProcessInfo.processInfo.environment
            guard env["CASSINI_HANDSET_QUAL"] == "1" else { return nil }
            var cfg = QualConfig()
            if let s = env["CASSINI_QUAL_SHORT_SECONDS"].flatMap(Int.init), s > 0 { cfg.shortSeconds = s }
            if let l = env["CASSINI_QUAL_LONG_SECONDS"].flatMap(Int.init), l > 0 { cfg.longSeconds = l }
            if env["CASSINI_QUAL_PARAKEET"] == "0" { cfg.runParakeet = false }
            if env["CASSINI_QUAL_WHISTLE"] == "0" { cfg.runWhistle = false }
            if env["CASSINI_QUAL_LONG_PARAKEET"] == "0" { cfg.runLongParakeet = false }
            if env["CASSINI_QUAL_LONG_WHISTLE"] == "1" { cfg.runLongWhistle = true }
            return cfg
        }
    }

    // MARK: - Telemetry

    struct TelemetrySnapshot: Codable, Sendable {
        let deviceIdentifier: String
        let osVersion: String
        let physicalMemoryMiB: Double
        let wallSeconds: Double
        let cpuUserSeconds: Double
        let cpuSystemSeconds: Double
        let cpuTotalSeconds: Double
        let baselineFootprintMiB: Double
        let peakFootprintMiB: Double
        let peakResidentMiB: Double
        let minAvailableMemoryMiB: Double
        let memoryWarnings: Int
        let maxThermalState: String
        let thermalTimeline: [String]
        let batteryStartPercent: Int
        let batteryEndPercent: Int
        let batteryState: String
    }

    final class HandsetTelemetryMonitor: @unchecked Sendable {
        private struct State {
            var baselineFootprint: UInt64 = 0
            var peakFootprint: UInt64 = 0
            var peakResident: UInt64 = 0
            var minAvailable: UInt64?
            var warnings = 0
            var maxThermal = 0
            var thermalTimeline: [String] = []
            var sampleTicks = 0
        }

        private let state = Mutex(State())
        private let startedWall = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        private let startRusage: rusage
        private let batteryStart: Int
        private let timer: DispatchSourceTimer
        private var warningObserver: (any NSObjectProtocol)?

        @MainActor
        static func start() -> HandsetTelemetryMonitor {
            UIDevice.current.isBatteryMonitoringEnabled = true
            let level = UIDevice.current.batteryLevel
            let batteryStart = level >= 0 ? Int((level * 100).rounded()) : -1
            return HandsetTelemetryMonitor(batteryStart: batteryStart)
        }

        private init(batteryStart: Int) {
            self.batteryStart = batteryStart
            var ru = rusage()
            getrusage(RUSAGE_SELF, &ru)
            self.startRusage = ru
            self.timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.codemyriad.cassini.qual.telemetry"))
            sample(baseline: true)
            self.warningObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.state.withLock { $0.warnings += 1 }
            }
            timer.setEventHandler { [weak self] in self?.sample(baseline: false) }
            timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
            timer.resume()
        }

        deinit {
            timer.cancel()
            if let warningObserver { NotificationCenter.default.removeObserver(warningObserver) }
        }

        nonisolated func sample(baseline: Bool) {
            var vm = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            let kr = withUnsafeMutablePointer(to: &vm) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            guard kr == KERN_SUCCESS else { return }
            let avail = UInt64(os_proc_available_memory())
            let footprint = vm.phys_footprint
            let peak = UInt64(vm.ledger_phys_footprint_peak)
            let resident = vm.resident_size_peak
            let thermal = ProcessInfo.processInfo.thermalState.rawValue
            state.withLock { s in
                if baseline { s.baselineFootprint = footprint }
                s.peakFootprint = max(s.peakFootprint, footprint, peak)
                s.peakResident = max(s.peakResident, resident)
                if avail > 0 { s.minAvailable = min(s.minAvailable ?? avail, avail) }
                s.maxThermal = max(s.maxThermal, thermal)
                if baseline || s.sampleTicks % 60 == 0 {
                    s.thermalTimeline.append(Self.thermalName(thermal))
                }
                s.sampleTicks += 1
            }
        }

        @MainActor
        func finish() -> TelemetrySnapshot {
            timer.cancel()
            sample(baseline: false)
            var endRu = rusage()
            getrusage(RUSAGE_SELF, &endRu)
            let userSec = Self.timevalSeconds(endRu.ru_utime) - Self.timevalSeconds(startRusage.ru_utime)
            let sysSec = Self.timevalSeconds(endRu.ru_stime) - Self.timevalSeconds(startRusage.ru_stime)
            let wallSec = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - startedWall) / 1_000_000_000.0
            let endLevel = UIDevice.current.batteryLevel
            let batteryEnd = endLevel >= 0 ? Int((endLevel * 100).rounded()) : -1
            let batteryStateStr: String = switch UIDevice.current.batteryState {
            case .unplugged: "unplugged"
            case .charging: "charging"
            case .full: "full"
            default: "unknown"
            }
            return state.withLock { s in
                TelemetrySnapshot(
                    deviceIdentifier: Self.machineIdentifier(),
                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
                    physicalMemoryMiB: Double(ProcessInfo.processInfo.physicalMemory) / (1024.0 * 1024.0),
                    wallSeconds: wallSec,
                    cpuUserSeconds: max(0, userSec),
                    cpuSystemSeconds: max(0, sysSec),
                    cpuTotalSeconds: max(0, userSec + sysSec),
                    baselineFootprintMiB: Double(s.baselineFootprint) / (1024.0 * 1024.0),
                    peakFootprintMiB: Double(s.peakFootprint) / (1024.0 * 1024.0),
                    peakResidentMiB: Double(s.peakResident) / (1024.0 * 1024.0),
                    minAvailableMemoryMiB: Double(s.minAvailable ?? 0) / (1024.0 * 1024.0),
                    memoryWarnings: s.warnings,
                    maxThermalState: Self.thermalName(s.maxThermal),
                    thermalTimeline: s.thermalTimeline,
                    batteryStartPercent: batteryStart,
                    batteryEndPercent: batteryEnd,
                    batteryState: batteryStateStr
                )
            }
        }

        private static func timevalSeconds(_ tv: timeval) -> Double {
            Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000.0
        }

        static func thermalName(_ raw: Int) -> String {
            switch raw {
            case ProcessInfo.ThermalState.nominal.rawValue: "nominal"
            case ProcessInfo.ThermalState.fair.rawValue: "fair"
            case ProcessInfo.ThermalState.serious.rawValue: "serious"
            case ProcessInfo.ThermalState.critical.rawValue: "critical"
            default: "unknown(\(raw))"
            }
        }

        static func machineIdentifier() -> String {
            var info = utsname()
            uname(&info)
            return withUnsafePointer(to: &info.machine) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
            }
        }
    }

    // MARK: - Always-on fast contract test (simulator & CI)

    @MainActor
    func testQualificationHarnessAndTelemetryContract() async throws {
        // 1. Telemetry monitor collects valid process metrics without sleeping.
        let monitor = HandsetTelemetryMonitor.start()
        // Exercise background-queue sampling (matching DispatchSourceTimer) to verify no MainActor isolation trap.
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                monitor.sample(baseline: false)
                cont.resume()
            }
        }
        let snap = monitor.finish()
        XCTAssertFalse(snap.deviceIdentifier.isEmpty)
        XCTAssertGreaterThan(snap.physicalMemoryMiB, 0)
        XCTAssertGreaterThanOrEqual(snap.peakFootprintMiB, snap.baselineFootprintMiB)
        XCTAssertGreaterThanOrEqual(snap.cpuTotalSeconds, 0)

        // 2. Unfinalized (-1) vs finalized CAF prefix SHA-256 equivalence.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qual-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let pcm = Self.makeTonePCM16LE(seconds: 4, sampleRate: 48_000)
        let growingURL = dir.appendingPathComponent("growing.caf")
        let finalURL = dir.appendingPathComponent("final.caf")
        try Self.writeCAF(to: growingURL, sampleRate: 48_000, pcm: pcm, finalized: false)
        try Self.writeCAF(to: finalURL, sampleRate: 48_000, pcm: pcm, finalized: true)

        let liveReader = try LiveCAFReader(url: growingURL)
        defer { liveReader.close() }
        let finalReader = try LiveCAFReader(url: finalURL)
        defer { finalReader.close() }

        let prefixFrames: UInt64 = 2 * 48_000 + 48
        XCTAssertEqual(try liveReader.prefixSHA256(committedFrames: prefixFrames),
                       try finalReader.prefixSHA256(committedFrames: prefixFrames))

        // 3. Simulated AVAudioSession interruption & route-change hooks on AVCaptureAdapter.
        final class FakeCaptureRecorder: CaptureRecorder {
            var delegate: (any AVAudioRecorderDelegate)?
            var isMeteringEnabled = false
            var currentTime: TimeInterval = 1.5
            let url: URL
            var pauseCount = 0
            var stopCount = 0
            init(url: URL) { self.url = url }
            func record() -> Bool { true }
            func pause() { pauseCount += 1 }
            func stop() { stopCount += 1 }
            func updateMeters() {}
            func averagePower(forChannel channelNumber: Int) -> Float { -12 }
        }
        let fakeRec = FakeCaptureRecorder(url: finalURL)
        let session = CaptureSession(requestPermission: { true }, prepare: {}, activate: {}, deactivate: {})
        let adapter = AVCaptureAdapter(session: session, makeRecorder: { _ in fakeRec })
        _ = try await adapter.start(url: finalURL)

        var received: [CaptureEvent] = []
        let collector = Task {
            for await event in adapter.events {
                if case .level = event { continue }
                received.append(event)
                if received.count == 2 { break }
            }
        }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        try adapter.resume()
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        await collector.value
        _ = try await adapter.stop()
        XCTAssertEqual(received, [.interrupted, .routeLost])
        XCTAssertEqual(fakeRec.pauseCount, 2)

        // 4. PrecomputePressure yields immediately under thermal .serious, low memory, and backgrounding.
        XCTAssertTrue(PrecomputePressure(isAppActive: { true }, thermalState: { .serious }, availableMemory: { 2 << 30 }).shouldYield())
        XCTAssertTrue(PrecomputePressure(isAppActive: { false }, thermalState: { .nominal }, availableMemory: { 2 << 30 }).shouldYield())
        XCTAssertTrue(PrecomputePressure(isAppActive: { true }, thermalState: { .nominal }, availableMemory: { 50 << 20 }).shouldYield(minMemoryBytes: ParakeetMemory.beforeWindowBytes))
        XCTAssertFalse(PrecomputePressure(isAppActive: { true }, thermalState: { .nominal }, availableMemory: { 2 << 30 }).shouldYield(minMemoryBytes: ParakeetMemory.beforeWindowBytes))

        // 5. Production RecordingController finalization (afterStop -> M4A vs transcribeWhileRecording -> CAF)
        //    and PortableExportService export produce verified CassiniDocuments with matching decoded audio duration.
        let afterStopProd = try await runProductionFinalizationAndExportContract(
            root: dir.appendingPathComponent("prod-afterStop", isDirectory: true),
            pcm: pcm,
            mode: .afterStop,
            hasPrecomputeCheckpoint: false
        )
        let headStartProd = try await runProductionFinalizationAndExportContract(
            root: dir.appendingPathComponent("prod-headStart", isDirectory: true),
            pcm: pcm,
            mode: .transcribeWhileRecording,
            hasPrecomputeCheckpoint: true
        )
        XCTAssertEqual(afterStopProd.audioFilename, RecordingController.compressedFilename)
        XCTAssertEqual(headStartProd.audioFilename, RecordingController.captureFilename)
        XCTAssertTrue(afterStopProd.exportVerified)
        XCTAssertTrue(headStartProd.exportVerified)
        XCTAssertLessThan(abs(afterStopProd.exportedDurationSeconds - headStartProd.exportedDurationSeconds), 0.15)
    }

    func testWordErrorRateEdgeCases() {
        let w: (String) -> ComparableWord = { ComparableWord(text: $0, startMs: 0, endMs: 100, speaker: nil) }
        XCTAssertEqual(Self.wordErrorRate(reference: [], hypothesis: []), 0.0)
        XCTAssertEqual(Self.wordErrorRate(reference: [], hypothesis: [w("hello")]), 1.0)
        XCTAssertEqual(Self.wordErrorRate(reference: [w("hello"), w("world")], hypothesis: []), 1.0)
        XCTAssertEqual(Self.wordErrorRate(reference: [w("hello")], hypothesis: [w("...")]), 1.0)
        XCTAssertEqual(Self.wordErrorRate(reference: [w("Hello,"), w("world!")], hypothesis: [w("hello"), w("world")]), 0.0)
        XCTAssertEqual(Self.wordErrorRate(reference: [w("hello"), w("world")], hypothesis: [w("hello"), w("mars")]), 0.5)
    }

    // MARK: - Opt-in Physical Handset Test 1: Real AVAudioRecorder + LiveCAFReader + Interruption Lifecycle

    @MainActor
    func test01RealCAFLiveReaderAndInterruptionLifecycle() async throws {
        guard QualConfig.load() != nil else {
            throw XCTSkip("opt-in physical handset qualification (set CASSINI_HANDSET_QUAL=1 or bundle CassiniHandsetQual.json)")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qual-caf-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let monitor = HandsetTelemetryMonitor.start()
        let cafURL = dir.appendingPathComponent("capture.caf")
        let adapter = AVCaptureAdapter()
        var report: [String: Any] = ["test": "test01RealCAFLiveReaderAndInterruptionLifecycle"]

        // Attempt real microphone capture when permission is already granted; fail fast if start fails.
        // Reserve the synthetic fallback strictly for non-granted (headless Device Farm) runs, which
        // cannot dismiss a modal iOS permission alert and would block until timeout.
        let micPermission = AVAudioApplication.shared.recordPermission
        var usedHardwareMic = false
        if micPermission == .granted {
            _ = try await adapter.start(url: cafURL)
            usedHardwareMic = true
        } else {
            report["microphoneStatus"] = "permission_\(micPermission == .denied ? "denied" : "undetermined")_headless_xctest"
        }

        if !usedHardwareMic {
            // Exercise the full LiveCAFReader growing -> finalized CAF prefix equivalence + interruption/route-change
            // + pause/resume + Opus publication lifecycle on real hardware without triggering the modal mic prompt.
            let prefixPCM = Self.makeTonePCM16LE(seconds: 4, sampleRate: 48_000)
            let fullPCM = Self.makeTonePCM16LE(seconds: 8, sampleRate: 48_000)
            try Self.writeCAF(to: cafURL, sampleRate: 48_000, pcm: prefixPCM, finalized: false)
            let liveReader = try LiveCAFReader(url: cafURL)
            let safeFrames1 = try liveReader.safeThroughFrame(safetyMarginFrames: LiveCAFReader.defaultSafetyMarginFrames)
            let liveSha1 = try liveReader.prefixSHA256(committedFrames: safeFrames1)
            liveReader.close()

            final class LifecycleRecorder: CaptureRecorder {
                var delegate: (any AVAudioRecorderDelegate)?
                var isMeteringEnabled = false
                var currentTime: TimeInterval = 4.0
                let url: URL
                var pauses = 0
                init(url: URL) { self.url = url }
                func record() -> Bool { true }
                func pause() { pauses += 1 }
                func stop() {}
                func updateMeters() {}
                func averagePower(forChannel channelNumber: Int) -> Float { -10 }
            }
            let fakeRec = LifecycleRecorder(url: cafURL)
            let fakeSession = CaptureSession(requestPermission: { true }, prepare: {}, activate: {}, deactivate: {})
            let lifecycleAdapter = AVCaptureAdapter(session: fakeSession, makeRecorder: { _ in fakeRec })
            _ = try await lifecycleAdapter.start(url: cafURL)
            let events = Mutex<[String]>([])
            let watcher = Task {
                for await ev in lifecycleAdapter.events {
                    switch ev {
                    case .interrupted: events.withLock { $0.append("interrupted") }
                    case .routeLost: events.withLock { $0.append("routeLost") }
                    case .failed: events.withLock { $0.append("failed") }
                    case .mediaReset: events.withLock { $0.append("mediaReset") }
                    case .level: break
                    }
                    if events.withLock({ $0.count >= 2 }) { break }
                }
            }
            lifecycleAdapter.pause()
            try lifecycleAdapter.resume()
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
            )
            try lifecycleAdapter.resume()
            NotificationCenter.default.post(
                name: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
            )
            await watcher.value
            _ = try await lifecycleAdapter.stop()

            try Self.writeCAF(to: cafURL, sampleRate: 48_000, pcm: fullPCM, finalized: true)
            let finalReader = try LiveCAFReader(url: cafURL)
            defer { finalReader.close() }
            let finalSha1 = try finalReader.prefixSHA256(committedFrames: safeFrames1)
            XCTAssertEqual(liveSha1, finalSha1)

            let opusURL = dir.appendingPathComponent("published.opus")
            try OpusAudio.encode(cafURL, to: opusURL)
            let opusBytes = try Data(contentsOf: opusURL)
            XCTAssertGreaterThan(opusBytes.count, 0)

            let observedEvents = events.withLock { $0 }
            XCTAssertTrue(observedEvents.contains("interrupted"))
            XCTAssertTrue(observedEvents.contains("routeLost"))
            let snap = monitor.finish()
            report["livePrefix1Frames"] = safeFrames1
            report["finalFrames"] = try finalReader.availableFrames()
            report["prefix1Matched"] = (liveSha1 == finalSha1)
            report["observedEvents"] = observedEvents
            report["opusBytes"] = opusBytes.count
            report["telemetry"] = try Self.asDictionary(snap)
            emitReport(name: "test01-caf-lifecycle", report: report)
            return
        }

        // Start event-gated observer immediately after hardware capture begins (zero fixed sleeps).
        let eventGate = CaptureEventGate(stream: adapter.events)
        defer { eventGate.cancel() }

        // Wait until AVAudioRecorder flushes >= 1 s of PCM16LE frames to capture.caf while live.
        let liveReader = try await waitForLiveCAFReader(at: cafURL, timeout: .seconds(15))
        let safeFrames1 = try await waitForCAFSafeFrames(
            reader: liveReader,
            atLeast: 48_000,
            timeout: .seconds(15),
            description: "initial AVAudioRecorder live CAF flush (>= 1 s)"
        )
        let liveSha1 = try liveReader.prefixSHA256(committedFrames: safeFrames1)

        // Pause -> Resume lifecycle: verify resume()'s async session activation completes via CAF frame growth.
        adapter.pause()
        let framesAtPause = try liveReader.safeThroughFrame(safetyMarginFrames: LiveCAFReader.defaultSafetyMarginFrames)
        try adapter.resume()
        let framesAfterResume = try await waitForCAFSafeFrames(
            reader: liveReader,
            atLeast: framesAtPause + 48_000,
            timeout: .seconds(15),
            description: "CAF frame growth after pause -> resume"
        )

        // Simulated incoming call audio interruption (began -> ended) + recovery.
        // Await the observed .interrupted event before ending the interruption and resuming.
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        try await eventGate.waitFor("interrupted", count: 1, timeout: .seconds(15))
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [
                AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                AVAudioSessionInterruptionOptionKey: AVAudioSession.InterruptionOptions.shouldResume.rawValue
            ]
        )
        let framesBeforeInterruptResume = max(
            framesAfterResume,
            try liveReader.safeThroughFrame(safetyMarginFrames: LiveCAFReader.defaultSafetyMarginFrames)
        )
        try adapter.resume()
        let framesAfterInterruptResume = try await waitForCAFSafeFrames(
            reader: liveReader,
            atLeast: framesBeforeInterruptResume + 24_000,
            timeout: .seconds(15),
            description: "CAF frame growth after interruption recovery resume"
        )

        // Simulated Bluetooth headset disconnect (oldDeviceUnavailable) + recovery.
        // Await the observed .routeLost event before resuming and verifying CAF frame growth.
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        try await eventGate.waitFor("routeLost", count: 1, timeout: .seconds(15))
        let framesBeforeRouteResume = max(
            framesAfterInterruptResume,
            try liveReader.safeThroughFrame(safetyMarginFrames: LiveCAFReader.defaultSafetyMarginFrames)
        )
        try adapter.resume()
        let safeFrames2 = try await waitForCAFSafeFrames(
            reader: liveReader,
            atLeast: framesBeforeRouteResume + 24_000,
            timeout: .seconds(15),
            description: "CAF frame growth after route-loss recovery resume"
        )

        // Capture second live prefix SHA-256 before Stop.
        XCTAssertGreaterThan(safeFrames2, safeFrames1)
        let liveSha2 = try liveReader.prefixSHA256(committedFrames: safeFrames2)
        liveReader.close()

        // Finalize via AVAudioRecorder.stop() and compare prefix hashes + Opus publication.
        let finalElapsed = adapter.elapsed
        _ = try await adapter.stop()
        eventGate.cancel()

        let finalReader = try LiveCAFReader(url: cafURL)
        defer { finalReader.close() }
        let finalFrames = try finalReader.availableFrames()
        let finalSha1 = try finalReader.prefixSHA256(committedFrames: safeFrames1)
        let finalSha2 = try finalReader.prefixSHA256(committedFrames: safeFrames2)
        XCTAssertEqual(liveSha1, finalSha1, "Live CAF prefix 1 must match finalized CAF bit-for-bit after AVAudioRecorder.stop()")
        XCTAssertEqual(liveSha2, finalSha2, "Live CAF prefix 2 must match finalized CAF bit-for-bit after AVAudioRecorder.stop()")

        let avFile = try AVAudioFile(forReading: cafURL)
        let fileDuration = Double(avFile.length) / avFile.fileFormat.sampleRate
        XCTAssertGreaterThan(avFile.length, 0)
        XCTAssertLessThan(abs(fileDuration - finalElapsed), 0.5, "Finalized CAF frame count must match active recording duration")

        // Verify Opus publication succeeds on the finalized CAF.
        let opusURL = dir.appendingPathComponent("published.opus")
        try OpusAudio.encode(cafURL, to: opusURL)
        let opusBytes = try Data(contentsOf: opusURL)
        XCTAssertGreaterThan(opusBytes.count, 0)

        let observedEvents = eventGate.observedEvents
        XCTAssertTrue(observedEvents.contains("interrupted"))
        XCTAssertTrue(observedEvents.contains("routeLost"))
        XCTAssertFalse(observedEvents.contains("failed"))

        let snap = monitor.finish()
        report["microphoneStatus"] = "ok"
        report["livePrefix1Frames"] = safeFrames1
        report["livePrefix2Frames"] = safeFrames2
        report["finalFrames"] = finalFrames
        report["finalDurationSeconds"] = fileDuration
        report["prefix1Matched"] = (liveSha1 == finalSha1)
        report["prefix2Matched"] = (liveSha2 == finalSha2)
        report["observedEvents"] = observedEvents
        report["opusBytes"] = opusBytes.count
        report["telemetry"] = try Self.asDictionary(snap)
        emitReport(name: "test01-caf-lifecycle", report: report)
    }

    // MARK: - Opt-in Physical Handset Test 2: Paired Equivalence + 5-min Metrics (Parakeet & Whistle) + Pressure Injection

    @MainActor
    func test02PairedEquivalenceAnd5MinMetrics() async throws {
        guard let config = QualConfig.load() else {
            throw XCTSkip("opt-in physical handset qualification (set CASSINI_HANDSET_QUAL=1 or bundle CassiniHandsetQual.json)")
        }
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without SherpaRuntime")

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("qual-5min-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let modelsRoot = try await Self.ensurePinnedModelsInstalled(in: workDir)
        let (speechPCM, speakerSamples16k) = try Self.makeMultiSpeakerSpeech48kPCM16LE(totalSeconds: config.shortSeconds)

        // Enroll >= 3 distinct saved voices using real CAM++ voiceprint extraction.
        let campplusURL = URL(fileURLWithPath: ModelCatalog.voiceprint.path(in: modelsRoot, ModelCatalog.voiceprintModel.name))
        let enrolledVoices = try Self.extractEnrolledVoices(campplusURL: campplusURL, speakerSamples16k: speakerSamples16k)
        XCTAssertGreaterThanOrEqual(enrolledVoices.count, 3, "D-1126 requires >= 3 enrolled saved voices")

        var report: [String: Any] = [
            "test": "test02PairedEquivalenceAnd5MinMetrics",
            "audioSeconds": config.shortSeconds,
            "enrolledVoiceCount": enrolledVoices.count,
            "device": HandsetTelemetryMonitor.machineIdentifier(),
            "os": ProcessInfo.processInfo.operatingSystemVersionString
        ]

        // Record-only control via production RecordingController (zero ML during recording, zero auto-enqueue on Stop).
        do {
            let controlRoot = workDir.appendingPathComponent("record-only", isDirectory: true)
            try FileManager.default.createDirectory(at: controlRoot, withIntermediateDirectories: true)
            let notes = try NoteStore(root: controlRoot.appendingPathComponent("notes", isDirectory: true))
            let recordingNotes = CountingRecordingNotes(store: notes)
            let handoff = FakeRecordingHandoff()
            let precomputeSpy = SpyPrecompute()
            let clock = SystemClock()
            let suite = "io.codemyriad.cassini.qual.recordonly.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let settings = SettingsStore(defaults: defaults, clock: clock, defaultLanguage: "en-US")
            settings.recordConsent()
            settings.transcriptionMode = .recordOnly

            let capture = QualFileCapture(prefixPCM: nil, fullPCM: speechPCM)
            let controller = RecordingController(parts: .init(
                ready: {},
                notes: recordingNotes,
                capture: capture,
                storage: UnlimitedStorage(),
                audio: LocalAudioProcessing(),
                settings: settings,
                handoff: handoff,
                consent: ModelConsent { _, _ in true },
                clock: clock,
                defaultTitle: { _ in "Record Only Control" },
                precompute: precomputeSpy
            ))

            let mon = HandsetTelemetryMonitor.start()
            XCTAssertTrue(controller.start())
            _ = try await waitForActiveRecording(controller: controller, timeout: .seconds(15))
            controller.finish()
            await controller.settle()
            let snap = mon.finish()

            XCTAssertEqual(precomputeSpy.startCount, 0, "recordOnly must never start recording-time precomputation")
            XCTAssertTrue(handoff.handedOff.isEmpty, "recordOnly must never hand off to transcription on Stop")
            report["recordOnly"] = try Self.asDictionary(snap)
        }

        // Parakeet + Sortformer + CAM++ paired run (production afterStop M4A, identical-CAF control,
        // production transcribeWhileRecording CAF, and pressure injection).
        if config.runParakeet {
            let parakeetBaseline = try await runParakeetPairedLane(
                root: workDir.appendingPathComponent("parakeet-afterStop-m4a", isDirectory: true),
                modelsRoot: modelsRoot,
                fullPCM: speechPCM,
                precomputePrefixSeconds: nil,
                enrolledVoices: enrolledVoices,
                injectPressureAtWindow: nil,
                preserveCAFWithoutCheckpoint: false
            )
            let parakeetCafControl = try await runParakeetPairedLane(
                root: workDir.appendingPathComponent("parakeet-afterStop-caf", isDirectory: true),
                modelsRoot: modelsRoot,
                fullPCM: speechPCM,
                precomputePrefixSeconds: nil,
                enrolledVoices: enrolledVoices,
                injectPressureAtWindow: nil,
                preserveCAFWithoutCheckpoint: true
            )
            let precomputeSeconds = max(60, config.shortSeconds - 15)
            let parakeetHeadStart = try await runParakeetPairedLane(
                root: workDir.appendingPathComponent("parakeet-headStart", isDirectory: true),
                modelsRoot: modelsRoot,
                fullPCM: speechPCM,
                precomputePrefixSeconds: precomputeSeconds,
                enrolledVoices: enrolledVoices,
                injectPressureAtWindow: nil,
                preserveCAFWithoutCheckpoint: false
            )
            // Production finalization & PortableExportService verification.
            XCTAssertEqual(parakeetBaseline.audioFilename, RecordingController.compressedFilename,
                           "Production afterStop must finalize to audio.m4a via RecordingController.finishAudio")
            XCTAssertEqual(parakeetHeadStart.audioFilename, RecordingController.captureFilename,
                           "Production transcribeWhileRecording with checkpoint must preserve capture.caf")
            XCTAssertTrue(parakeetBaseline.exportVerified, "Production afterStop PortableExportService .opus must verify .ok")
            XCTAssertTrue(parakeetHeadStart.exportVerified, "Production transcribeWhileRecording PortableExportService .opus must verify .ok")
            XCTAssertLessThan(abs(parakeetHeadStart.exportedDurationSeconds - parakeetBaseline.exportedDurationSeconds), 0.15,
                              "Production afterStop (M4A->Opus) and transcribeWhileRecording (CAF->Opus) exported durations must match")

            // Production end-to-end equivalence (M4A afterStop vs CAF transcribeWhileRecording).
            let parakeetProductionWER = Self.wordErrorRate(reference: parakeetBaseline.words, hypothesis: parakeetHeadStart.words)
            XCTAssertLessThanOrEqual(parakeetProductionWER, 0.02,
                                     "Production Parakeet afterStop (M4A) vs transcribeWhileRecording (CAF) WER must be <= 2%")
            XCTAssertEqual(parakeetHeadStart.speakerCount, parakeetBaseline.speakerCount,
                           "Production Parakeet speaker count must match across M4A vs CAF finalization")
            XCTAssertEqual(parakeetHeadStart.matchedVoiceNames, parakeetBaseline.matchedVoiceNames,
                           "Production Parakeet CAM++ saved-voice matches must match across M4A vs CAF finalization")

            // Strict identical-audio checkpoint equivalence (D109 §1.3: zero drift from CAF prefix resume).
            XCTAssertEqual(parakeetHeadStart.opusSha256, parakeetCafControl.opusSha256, "Identical-CAF Parakeet .opus payload must match")
            XCTAssertEqual(parakeetHeadStart.words, parakeetCafControl.words, "Identical-CAF Parakeet words & timings must match")
            XCTAssertEqual(parakeetHeadStart.speakerTurns, parakeetCafControl.speakerTurns, "Identical-CAF Parakeet Sortformer speaker turns must match")
            XCTAssertEqual(parakeetHeadStart.matchedVoiceNames, parakeetCafControl.matchedVoiceNames, "Identical-CAF Parakeet CAM++ saved-voice matches must match")
            XCTAssertGreaterThan(parakeetHeadStart.precomputeCheckpointsSaved, 0)
            XCTAssertLessThan(parakeetHeadStart.postStopWindowsDecoded, parakeetBaseline.postStopWindowsDecoded,
                              "Head-start must decode fewer post-Stop windows than afterStop")

            // Pressure injection check (thermal .serious + low memory + backgrounding after 2 windows -> tail completes identically).
            let parakeetPressure = try await runParakeetPairedLane(
                root: workDir.appendingPathComponent("parakeet-pressure", isDirectory: true),
                modelsRoot: modelsRoot,
                fullPCM: speechPCM,
                precomputePrefixSeconds: precomputeSeconds,
                enrolledVoices: enrolledVoices,
                injectPressureAtWindow: 2,
                preserveCAFWithoutCheckpoint: false
            )
            XCTAssertEqual(parakeetPressure.words, parakeetCafControl.words, "Parakeet pressure-yield tail recovery must match identical-CAF afterStop")
            XCTAssertEqual(parakeetPressure.speakerTurns, parakeetCafControl.speakerTurns)
            XCTAssertEqual(parakeetPressure.matchedVoiceNames, parakeetCafControl.matchedVoiceNames)

            report["parakeet"] = [
                "equivalencePassed": true,
                "productionFinalizationChecked": true,
                "productionAfterStopAudioFilename": parakeetBaseline.audioFilename,
                "productionHeadStartAudioFilename": parakeetHeadStart.audioFilename,
                "productionM4aVsCafWER": parakeetProductionWER,
                "productionM4aVsCafExactWords": (parakeetHeadStart.words == parakeetBaseline.words),
                "productionM4aVsCafDurationDeltaSeconds": abs(parakeetHeadStart.exportedDurationSeconds - parakeetBaseline.exportedDurationSeconds),
                "pressureRecoveryPassed": true,
                "wordCount": parakeetBaseline.words.count,
                "speakerCount": parakeetBaseline.speakerCount,
                "matchedVoices": parakeetBaseline.matchedVoiceNames,
                "afterStopStopToPublishedSeconds": parakeetBaseline.stopToPublishedSeconds,
                "headStartStopToPublishedSeconds": parakeetHeadStart.stopToPublishedSeconds,
                "afterStopPostStopWindows": parakeetBaseline.postStopWindowsDecoded,
                "headStartPostStopWindows": parakeetHeadStart.postStopWindowsDecoded,
                "pressurePostStopWindows": parakeetPressure.postStopWindowsDecoded,
                "afterStopTelemetry": try Self.asDictionary(parakeetBaseline.telemetry),
                "headStartTelemetry": try Self.asDictionary(parakeetHeadStart.telemetry),
                "headStartPrecomputeTelemetry": try Self.asDictionary(parakeetHeadStart.precomputeTelemetry ?? parakeetHeadStart.telemetry)
            ] as [String: Any]
        }

        // Whistle paired run (production afterStop M4A, identical-CAF control,
        // production transcribeWhileRecording CAF, and pressure injection).
        if config.runWhistle {
            let whistleBaseline = try await runWhistlePairedLane(
                root: workDir.appendingPathComponent("whistle-afterStop-m4a", isDirectory: true),
                fullPCM: speechPCM,
                precomputePrefixSeconds: nil,
                injectPressureAtCheckpoint: nil,
                preserveCAFWithoutCheckpoint: false
            )
            let whistleCafControl = try await runWhistlePairedLane(
                root: workDir.appendingPathComponent("whistle-afterStop-caf", isDirectory: true),
                fullPCM: speechPCM,
                precomputePrefixSeconds: nil,
                injectPressureAtCheckpoint: nil,
                preserveCAFWithoutCheckpoint: true
            )
            let precomputeSeconds = max(60, config.shortSeconds - 15)
            let whistleHeadStart = try await runWhistlePairedLane(
                root: workDir.appendingPathComponent("whistle-headStart", isDirectory: true),
                fullPCM: speechPCM,
                precomputePrefixSeconds: precomputeSeconds,
                injectPressureAtCheckpoint: nil,
                preserveCAFWithoutCheckpoint: false
            )
            XCTAssertEqual(whistleBaseline.audioFilename, RecordingController.compressedFilename,
                           "Production afterStop must finalize to audio.m4a via RecordingController.finishAudio")
            XCTAssertEqual(whistleHeadStart.audioFilename, RecordingController.captureFilename,
                           "Production transcribeWhileRecording with checkpoint must preserve capture.caf")
            XCTAssertTrue(whistleBaseline.exportVerified)
            XCTAssertTrue(whistleHeadStart.exportVerified)
            XCTAssertLessThan(abs(whistleHeadStart.exportedDurationSeconds - whistleBaseline.exportedDurationSeconds), 0.15)

            let whistleProductionWER = Self.wordErrorRate(reference: whistleBaseline.words, hypothesis: whistleHeadStart.words)
            XCTAssertLessThanOrEqual(whistleProductionWER, 0.02,
                                     "Production Whistle afterStop (M4A) vs transcribeWhileRecording (CAF) WER must be <= 2%")

            // Strict identical-audio checkpoint equivalence (D109 §1.3).
            XCTAssertEqual(whistleHeadStart.opusSha256, whistleCafControl.opusSha256, "Identical-CAF Whistle .opus payload must match")
            XCTAssertEqual(whistleHeadStart.words, whistleCafControl.words, "Identical-CAF Whistle words & timings must match")
            XCTAssertGreaterThan(whistleHeadStart.precomputeCheckpointsSaved, 0)
            XCTAssertLessThan(whistleHeadStart.postStopSegmentsDecoded, whistleBaseline.postStopSegmentsDecoded,
                              "Whistle head-start must decode fewer post-Stop segments than afterStop")

            let whistlePressure = try await runWhistlePairedLane(
                root: workDir.appendingPathComponent("whistle-pressure", isDirectory: true),
                fullPCM: speechPCM,
                precomputePrefixSeconds: precomputeSeconds,
                injectPressureAtCheckpoint: 3,
                preserveCAFWithoutCheckpoint: false
            )
            XCTAssertEqual(whistlePressure.words, whistleCafControl.words, "Whistle pressure-yield tail recovery must match identical-CAF afterStop")

            report["whistle"] = [
                "equivalencePassed": true,
                "productionFinalizationChecked": true,
                "productionAfterStopAudioFilename": whistleBaseline.audioFilename,
                "productionHeadStartAudioFilename": whistleHeadStart.audioFilename,
                "productionM4aVsCafWER": whistleProductionWER,
                "productionM4aVsCafExactWords": (whistleHeadStart.words == whistleBaseline.words),
                "productionM4aVsCafDurationDeltaSeconds": abs(whistleHeadStart.exportedDurationSeconds - whistleBaseline.exportedDurationSeconds),
                "pressureRecoveryPassed": true,
                "wordCount": whistleBaseline.words.count,
                "afterStopStopToPublishedSeconds": whistleBaseline.stopToPublishedSeconds,
                "headStartStopToPublishedSeconds": whistleHeadStart.stopToPublishedSeconds,
                "afterStopPostStopSegments": whistleBaseline.postStopSegmentsDecoded,
                "headStartPostStopSegments": whistleHeadStart.postStopSegmentsDecoded,
                "pressurePostStopSegments": whistlePressure.postStopSegmentsDecoded,
                "afterStopTelemetry": try Self.asDictionary(whistleBaseline.telemetry),
                "headStartTelemetry": try Self.asDictionary(whistleHeadStart.telemetry),
                "headStartPrecomputeTelemetry": try Self.asDictionary(whistleHeadStart.precomputeTelemetry ?? whistleHeadStart.telemetry)
            ] as [String: Any]
        }

        emitReport(name: "test02-paired-5min", report: report)
    }

    // MARK: - Opt-in Physical Handset Test 3: 30-min Continuous Capture Invulnerability (Parakeet)

    @MainActor
    func test03ThirtyMinuteContinuousParakeet() async throws {
        guard let config = QualConfig.load(), config.runLongParakeet else {
            throw XCTSkip("opt-in 30-min Parakeet continuous handset qualification")
        }
        try XCTSkipUnless(SherpaRuntime.isLinked, "built without SherpaRuntime")
        try await runThirtyMinuteContinuousCapture(engine: .parakeet, totalSeconds: config.longSeconds)
    }

    // MARK: - Opt-in Physical Handset Test 4: 30-min Continuous Capture Invulnerability (Whistle)

    @MainActor
    func test04ThirtyMinuteContinuousWhistle() async throws {
        guard let config = QualConfig.load(), config.runLongWhistle else {
            throw XCTSkip("opt-in 30-min Whistle continuous handset qualification")
        }
        try await runThirtyMinuteContinuousCapture(engine: .whistle, totalSeconds: config.longSeconds)
    }

    private enum LongEngine: String { case parakeet, whistle }

    @MainActor
    private func runThirtyMinuteContinuousCapture(engine: LongEngine, totalSeconds: Int) async throws {
        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("qual-long-\(engine.rawValue)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let modelsRoot: URL? = engine == .parakeet ? try await Self.ensurePinnedModelsInstalled(in: workDir) : nil
        // Keep only a single ~35 s multi-speaker cycle (~3.3 MiB) in memory and stream slices to disk
        // so the 30-min harness does not retain ~165 MiB of synthetic PCM in RAM during RSS telemetry.
        let cyclePCM = try Self.makeMultiSpeakerSpeechCycle48kPCM16LE()
        XCTAssertFalse(cyclePCM.isEmpty)

        let notesRoot = workDir.appendingPathComponent("notes", isDirectory: true)
        let notes = try NoteStore(root: notesRoot)
        var note = Note(title: "Long \(engine.rawValue)", audioFilename: "capture.caf")
        note.duration = Double(totalSeconds)
        try await notes.save(note)
        let speechCAF = notes.audioURL(for: note)
        // Start with an empty unfinalized CAF header and append 1 s/s in real time while AVAudioRecorder captures from hardware mic.
        try Self.writeCAF(to: speechCAF, sampleRate: 48_000, pcm: Data(), finalized: false)

        let checkpoints = CheckpointFiles(notes: notes)
        let provenance = ProvenanceFiles(notes: notes)
        let budget = NativeBudget()
        let savedCheckpoints = Mutex(0)

        let precomputer: CAFPrefixPrecomputer
        let analyzer: (any SpeakerAnalyzing)
        let transcriber: any Transcribing

        switch engine {
        case .parakeet:
            let mRoot = try XCTUnwrap(modelsRoot)
            let speakerRepo = ModelRepository(root: mRoot, consent: AlwaysConsent(), fetcher: UnavailableFetcher())
            let speakerInstaller = PinnedModelInstaller(models: speakerRepo, storage: UnlimitedStorage(), online: { false })
            let speakerModels = SpeakerModels(repository: speakerRepo, installer: speakerInstaller)
            let realAnalyzer = SpeakerAnalyzer(models: speakerModels, runtime: SherpaRuntime.speakers)
            analyzer = realAnalyzer
            let parakeetModels = ParakeetTranscriber.Models(root: mRoot)
            transcriber = ParakeetTranscriber(models: parakeetModels, runtime: SherpaRuntime.speech)
            precomputer = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: budget,
                mode: { .transcribeWhileRecording },
                engine: {
                    .parakeet(.init(
                        models: parakeetModels,
                        runtime: SherpaRuntime.speech,
                        speakerEngines: { await realAnalyzer.streamingEngines() },
                        identifySpeakers: { true },
                        printsReady: { await realAnalyzer.printsReady() }
                    ))
                },
                pressure: PrecomputePressure(isAppActive: { true }),
                onCheckpointSaved: { _, _ in savedCheckpoints.withLock { $0 += 1 } }
            )
        case .whistle:
            analyzer = FakeAnalyzer()
            let cap = WhistleCapability(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                        pipelineAccepted: true, deviceAccepted: true)
            transcriber = WhistleTranscriber(acceptance: cap)
            precomputer = CAFPrefixPrecomputer(
                checkpoints: checkpoints,
                budget: budget,
                mode: { .transcribeWhileRecording },
                engine: { .whistle(.init(acceptance: { cap }, bundle: .main)) },
                pressure: PrecomputePressure(isAppActive: { true }),
                onCheckpointSaved: { _, _ in savedCheckpoints.withLock { $0 += 1 } }
            )
        }

        // Start real AVAudioRecorder concurrently when microphone permission is already granted;
        // propagate start errors rather than silently skipping mic assertions. Reserve the no-mic
        // path strictly for non-granted (headless Device Farm) runs.
        let micCAF = workDir.appendingPathComponent("hardware-mic.caf")
        let micAdapter = AVCaptureAdapter()
        var micStarted = false
        var micError: String?
        let micPermission = AVAudioApplication.shared.recordPermission
        if micPermission == .granted {
            _ = try await micAdapter.start(url: micCAF)
            micStarted = true
        } else {
            micError = "permission_\(micPermission == .denied ? "denied" : "undetermined")_headless_xctest"
        }
        let micEvents = Mutex<[String]>([])
        let micWatcher = Task {
            for await ev in micAdapter.events {
                if case .level = ev { continue }
                micEvents.withLock { $0.append("\(ev)") }
            }
        }

        let monitor = HandsetTelemetryMonitor.start()
        precomputer.start(noteID: note.id, captureURL: speechCAF)

        // Pace appending 2 seconds of real 48 kHz PCM every 2 seconds for `totalSeconds` (real-time rate),
        // streaming slices from the bounded single-cycle buffer and tracking total bytes written.
        let writerHandle = try FileHandle(forWritingTo: speechCAF)
        try writerHandle.seekToEnd()
        let chunkSeconds = 2
        let bytesPerSecond = 48_000 * 2
        var writtenSeconds = 0
        var totalPCMBytesWritten: UInt64 = 0
        var cycleOffset = 0
        while writtenSeconds < totalSeconds {
            let nextEnd = min(totalSeconds, writtenSeconds + chunkSeconds)
            var remainingBytes = (nextEnd - writtenSeconds) * bytesPerSecond
            while remainingBytes > 0 {
                let take = min(remainingBytes, cyclePCM.count - cycleOffset)
                try writerHandle.write(contentsOf: cyclePCM[cycleOffset..<(cycleOffset + take)])
                totalPCMBytesWritten += UInt64(take)
                remainingBytes -= take
                cycleOffset = (cycleOffset + take) % cyclePCM.count
            }
            try writerHandle.synchronize()
            writtenSeconds = nextEnd
            if writtenSeconds < totalSeconds {
                try await Task.sleep(for: .seconds(chunkSeconds))
            }
        }
        try writerHandle.close()
        // Measure Stop-to-published-transcript latency from capture end (covering CAF finalization,
        // microphone stop, precomputer stop, and post-Stop TranscriptionJob completion).
        let stopStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        // Finalize the CAF header just as AVAudioRecorder.stop() does, using the streamed byte counter.
        try Self.finalizeCAFHeader(at: speechCAF, pcmBytes: totalPCMBytesWritten)

        // Stop hardware mic and precomputer.
        let micElapsed = micStarted ? micAdapter.elapsed : 0
        if micStarted { _ = try await micAdapter.stop() }
        micWatcher.cancel()
        await precomputer.stop(noteID: note.id)
        let recordingSnap = monitor.finish()

        // Ensure recording-time precomputation saved at least one checkpoint before starting the post-Stop job.
        let precomputeCheckpointsSaved = savedCheckpoints.withLock { $0 }
        XCTAssertGreaterThanOrEqual(
            precomputeCheckpointsSaved, 1,
            "30-min transcribeWhileRecording lane (\(engine.rawValue)) must save at least one recording-time checkpoint before Stop"
        )

        // Now run the post-Stop TranscriptionJob using the precompute checkpoint.
        let postStopMonitor = HandsetTelemetryMonitor.start()
        let job = TranscriptionJob(notes: notes, transcriber: transcriber, analyzer: analyzer,
                                   checkpoints: checkpoints, provenance: provenance,
                                   host: StaticJobHost(identifySpeakers: engine == .parakeet, voices: []),
                                   clock: SystemClock(), budget: budget)
        let outcome = await job.run(Job(noteID: note.id, seq: 1, kind: .transcribe, state: .running, enqueuedAt: Date()),
                                    stop: StopSignal()) { _ in }
        let stopToPublished = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - stopStart) / 1_000_000_000.0
        let postStopSnap = postStopMonitor.finish()
        XCTAssertEqual(outcome, JobOutcome.done)

        // Inspect hardware mic CAF for dropped frames / continuity (outside the Stop-to-published timer).
        var micFrames: Int64 = 0
        var micDuration: Double = 0
        var droppedFrameDriftSeconds: Double = 0
        if micStarted {
            let avFile = try AVAudioFile(forReading: micCAF)
            micFrames = avFile.length
            micDuration = Double(avFile.length) / avFile.fileFormat.sampleRate
            droppedFrameDriftSeconds = abs(micDuration - micElapsed)
            XCTAssertEqual(micEvents.withLock { $0 }.filter { $0.contains("failed") }, [], "Zero AVAudioRecorder encode errors")
            XCTAssertLessThan(droppedFrameDriftSeconds, 0.5, "Zero dropped AVAudioRecorder buffers over continuous capture")
        }

        let stored = await notes.note(note.id)
        let saved = try XCTUnwrap(stored)
        let wordCount = saved.transcript.flatMap(\.draftWords).count
        XCTAssertGreaterThan(wordCount, 0)

        let report: [String: Any] = [
            "test": "runThirtyMinuteContinuousCapture",
            "engine": engine.rawValue,
            "audioSeconds": totalSeconds,
            "precomputeCheckpointsSaved": precomputeCheckpointsSaved,
            "stopToPublishedSeconds": stopToPublished,
            "wordCount": wordCount,
            "micStarted": micStarted,
            "micError": micError ?? "none",
            "micElapsedSeconds": micElapsed,
            "micFinalDurationSeconds": micDuration,
            "micFinalFrames": micFrames,
            "micDriftSeconds": droppedFrameDriftSeconds,
            "micEvents": micEvents.withLock { $0 },
            "recordingTelemetry": try Self.asDictionary(recordingSnap),
            "postStopTelemetry": try Self.asDictionary(postStopSnap)
        ]
        emitReport(name: "test03-30min-\(engine.rawValue)", report: report)
    }

    // MARK: - Paired Lane Runners

    private struct ComparableWord: Equatable {
        let text: String
        let startMs: Int64
        let endMs: Int64
        let speaker: String?
    }

    private struct ComparableTurn: Equatable {
        let speaker: String
        let startMs: Int64
        let endMs: Int64
    }

    private struct PairedLaneResult {
        let audioFilename: String
        let exportVerified: Bool
        let exportedDurationSeconds: Double
        let opusSha256: String
        let words: [ComparableWord]
        let speakerTurns: [ComparableTurn]
        let speakerCount: Int
        let matchedVoiceNames: [String]
        let precomputeCheckpointsSaved: Int
        let postStopWindowsDecoded: Int
        let postStopSegmentsDecoded: Int
        let stopToPublishedSeconds: Double
        let telemetry: TelemetrySnapshot
        let precomputeTelemetry: TelemetrySnapshot?
    }

    private struct ProductionExportContractResult {
        let audioFilename: String
        let exportVerified: Bool
        let exportedDurationSeconds: Double
    }

    @MainActor
    private func runProductionFinalizationAndExportContract(
        root: URL,
        pcm: Data,
        mode: TranscriptionMode,
        hasPrecomputeCheckpoint: Bool
    ) async throws -> ProductionExportContractResult {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notes = try NoteStore(root: root.appendingPathComponent("notes", isDirectory: true))
        let provenance = ProvenanceFiles(notes: notes)
        let recordingNotes = CountingRecordingNotes(store: notes)
        let handoff = FakeRecordingHandoff()
        let clock = PermitClock(now: Date(timeIntervalSince1970: 1_791_366_060))
        let suite = "io.codemyriad.cassini.qual.contract.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, clock: clock, defaultLanguage: "en-US")
        settings.recordConsent()
        settings.transcriptionMode = mode

        let capture = QualFileCapture(prefixPCM: nil, fullPCM: pcm)
        let precomputeStub: (any RecordingPrecomputing)? = hasPrecomputeCheckpoint ? StaticCheckpointPrecompute() : nil
        let controller = RecordingController(parts: .init(
            ready: {},
            notes: recordingNotes,
            capture: capture,
            storage: UnlimitedStorage(),
            audio: LocalAudioProcessing(),
            settings: settings,
            handoff: handoff,
            consent: ModelConsent { _, _ in true },
            clock: clock,
            defaultTitle: { _ in "Qual Contract" },
            precompute: precomputeStub
        ))

        XCTAssertTrue(controller.start())
        let active = try await waitForActiveRecording(controller: controller, timeout: .seconds(15))
        controller.finish()
        await controller.settle()
        XCTAssertEqual(handoff.handedOff, [active.noteID])

        let fetchedSaved = await notes.note(active.noteID)
        let saved = try XCTUnwrap(fetchedSaved)
        let playableURL = notes.audioURL(for: saved)
        let exportDir = root.appendingPathComponent("export", isDirectory: true)
        let exporter = PortableExportService(audio: LocalAudioProcessing(), provenance: provenance, unassignedLabel: "Unassigned")
        let exportedURL = try await exporter.export(saved, original: playableURL, playable: playableURL, into: exportDir, filename: "published")
        let doc = CassiniDocument.read(exportedURL)
        let decodedCAF = root.appendingPathComponent("decoded-export.caf")
        try OpusAudio.decode(exportedURL, to: decodedCAF)
        defer { try? FileManager.default.removeItem(at: decodedCAF) }
        let decodedFile = try AVAudioFile(forReading: decodedCAF)
        let decodedDuration = Double(decodedFile.length) / decodedFile.fileFormat.sampleRate
        return ProductionExportContractResult(
            audioFilename: saved.audioFilename,
            exportVerified: doc.state == DocumentState.ok,
            exportedDurationSeconds: decodedDuration
        )
    }

    @MainActor
    private func runParakeetPairedLane(
        root: URL,
        modelsRoot: URL,
        fullPCM: Data,
        precomputePrefixSeconds: Int?,
        enrolledVoices: [SavedVoice],
        injectPressureAtWindow: Int?,
        preserveCAFWithoutCheckpoint: Bool
    ) async throws -> PairedLaneResult {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notes = try NoteStore(root: root.appendingPathComponent("notes", isDirectory: true))
        let checkpoints = CheckpointFiles(notes: notes)
        let provenance = ProvenanceFiles(notes: notes)
        let budget = NativeBudget()

        let speakerRepo = ModelRepository(root: modelsRoot, consent: AlwaysConsent(), fetcher: UnavailableFetcher())
        let speakerInstaller = PinnedModelInstaller(models: speakerRepo, storage: UnlimitedStorage(), online: { false })
        let speakerModels = SpeakerModels(repository: speakerRepo, installer: speakerInstaller)
        let analyzer = SpeakerAnalyzer(models: speakerModels, runtime: SherpaRuntime.speakers)
        let parakeetModels = ParakeetTranscriber.Models(root: modelsRoot)

        let recordingNotes = CountingRecordingNotes(store: notes)
        let handoff = FakeRecordingHandoff()
        let clock = SystemClock()
        let suite = "io.codemyriad.cassini.qual.parakeet.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, clock: clock, defaultLanguage: "en-US")
        settings.recordConsent()
        settings.transcriptionMode = precomputePrefixSeconds == nil ? TranscriptionMode.afterStop : .transcribeWhileRecording

        let prefixPCM: Data? = precomputePrefixSeconds.map { fullPCM.prefix(min(fullPCM.count, $0 * 48_000 * 2)) }
        let fileCapture = QualFileCapture(prefixPCM: prefixPCM, fullPCM: fullPCM)
        let audioProcessor: any AudioProcessing = preserveCAFWithoutCheckpoint ? NoCompressAudioProcessing() : LocalAudioProcessing()

        var precomputeSaved = 0
        var precomputeTelemetry: TelemetrySnapshot?
        let savedCounter = Mutex(0)
        let pressureInjected = Mutex(false)
        let countAtInjection = Mutex<Int?>(nil)
        let thermalInjected = Mutex(ProcessInfo.ThermalState.nominal)
        let memInjected = Mutex<Int64?>(nil)
        let activeInjected = Mutex(true)

        let precomputer: CAFPrefixPrecomputer? = precomputePrefixSeconds == nil ? nil : CAFPrefixPrecomputer(
            checkpoints: checkpoints,
            budget: budget,
            mode: { .transcribeWhileRecording },
            engine: {
                .parakeet(.init(
                    models: parakeetModels,
                    runtime: SherpaRuntime.speech,
                    speakerEngines: { await analyzer.streamingEngines() },
                    identifySpeakers: { true },
                    printsReady: { await analyzer.printsReady() }
                ))
            },
            pressure: PrecomputePressure(
                isAppActive: { activeInjected.withLock { $0 } },
                thermalState: { thermalInjected.withLock { $0 } },
                availableMemory: { memInjected.withLock { $0 } ?? TranscriptionJob.availableMemory() }
            ),
            onCheckpointSaved: { _, _ in
                let n = savedCounter.withLock { $0 += 1; return $0 }
                if let limit = injectPressureAtWindow, n >= limit {
                    let firstTrigger = pressureInjected.withLock { already -> Bool in
                        if already { return false }
                        already = true
                        return true
                    }
                    if firstTrigger {
                        countAtInjection.withLock { $0 = n }
                        thermalInjected.withLock { $0 = .serious }
                        memInjected.withLock { $0 = 10 << 20 }
                        activeInjected.withLock { $0 = false }
                    }
                }
            }
        )
        let bridge: (any RecordingPrecomputing)? = precomputer.map(ControlledPrecomputeBridge.init)

        let controller = RecordingController(parts: .init(
            ready: {},
            notes: recordingNotes,
            capture: fileCapture,
            storage: UnlimitedStorage(),
            audio: audioProcessor,
            settings: settings,
            handoff: handoff,
            consent: ModelConsent { _, _ in true },
            clock: clock,
            defaultTitle: { _ in "Parakeet Paired" },
            precompute: bridge
        ))

        XCTAssertTrue(controller.start())
        let active = try await waitForActiveRecording(controller: controller, timeout: .seconds(15))
        let noteID = active.noteID
        let fetchedActive = await notes.note(noteID)
        let activeNote = try XCTUnwrap(fetchedActive)
        let cafURL = notes.audioURL(for: activeNote)

        if let precomputer {
            let preMon = HandsetTelemetryMonitor.start()
            await precomputer.runOnce(noteID: noteID, captureURL: cafURL)
            precomputeTelemetry = preMon.finish()
            precomputeSaved = savedCounter.withLock { $0 }
            if let limit = injectPressureAtWindow {
                XCTAssertTrue(pressureInjected.withLock { $0 }, "Parakeet pressure injection must actually fire during precompute")
                let injectedAt = try XCTUnwrap(countAtInjection.withLock { $0 })
                XCTAssertGreaterThanOrEqual(injectedAt, limit, "Parakeet must save at least \(limit) checkpoint(s) before/at pressure injection")
                XCTAssertLessThanOrEqual(precomputeSaved - injectedAt, 1,
                                         "Parakeet precompute must pause within 1 window after pressure injection (saved \(precomputeSaved), injected at \(injectedAt))")
            }
        }

        // Production Stop -> RecordingController.finishAudio -> TranscriptionJob (timed);
        // PortableExportService export is verified separately afterward.
        let postStopWindows = Mutex(0)
        let host = MatchingJobHost(notes: notes, voices: enrolledVoices)
        let transcriber = ParakeetTranscriber(models: parakeetModels, runtime: SherpaRuntime.speech)
        let job = TranscriptionJob(notes: notes, transcriber: transcriber, analyzer: analyzer,
                                   checkpoints: checkpoints, provenance: provenance, host: host,
                                   clock: clock, budget: budget)

        let postMon = HandsetTelemetryMonitor.start()
        let started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        controller.finish()
        await controller.settle()
        XCTAssertEqual(handoff.handedOff, [noteID])

        let outcome = await job.run(Job(noteID: noteID, seq: 1, kind: .transcribe, state: .running, enqueuedAt: Date()),
                                    stop: StopSignal()) { event in
            if case .checkpointed = event { postStopWindows.withLock { $0 += 1 } }
        }
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - started) / 1_000_000_000.0
        let postSnap = postMon.finish()
        XCTAssertEqual(outcome, JobOutcome.done)

        let fetchedSaved = await notes.note(noteID)
        let saved = try XCTUnwrap(fetchedSaved)
        let finalAudioURL = notes.audioURL(for: saved)
        let exportDir = root.appendingPathComponent("export", isDirectory: true)
        let exporter = PortableExportService(audio: LocalAudioProcessing(), provenance: provenance, unassignedLabel: "Unassigned")
        let opusURL = try await exporter.export(saved, original: finalAudioURL, playable: finalAudioURL, into: exportDir, filename: "published")

        let doc = CassiniDocument.read(opusURL)
        // Ogg Opus headers include a per-encode random serial number, so compare the decoded PCM payload digest & duration.
        let decodedOpusCAF = root.appendingPathComponent("decoded-opus.caf")
        try OpusAudio.decode(opusURL, to: decodedOpusCAF)
        let decodedFile = try AVAudioFile(forReading: decodedOpusCAF)
        let exportedDuration = Double(decodedFile.length) / decodedFile.fileFormat.sampleRate
        let opusSha = SHA256.hash(data: try Data(contentsOf: decodedOpusCAF)).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(at: decodedOpusCAF)
        let words = saved.transcript.flatMap { seg in
            seg.draftWords.map { ComparableWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: seg.speaker) }
        }
        let turns = saved.transcript.compactMap { seg -> ComparableTurn? in
            guard let spk = seg.speaker else { return nil }
            return ComparableTurn(speaker: spk, startMs: Int64((seg.start * 1000).rounded()), endMs: Int64((seg.end * 1000).rounded()))
        }
        return PairedLaneResult(
            audioFilename: saved.audioFilename,
            exportVerified: doc.state == DocumentState.ok,
            exportedDurationSeconds: exportedDuration,
            opusSha256: opusSha,
            words: words,
            speakerTurns: turns,
            speakerCount: saved.speakers?.count ?? 0,
            matchedVoiceNames: host.matchedNames.sorted(),
            precomputeCheckpointsSaved: precomputeSaved,
            postStopWindowsDecoded: postStopWindows.withLock { $0 },
            postStopSegmentsDecoded: 0,
            stopToPublishedSeconds: elapsed,
            telemetry: postSnap,
            precomputeTelemetry: precomputeTelemetry
        )
    }

    @MainActor
    private func runWhistlePairedLane(
        root: URL,
        fullPCM: Data,
        precomputePrefixSeconds: Int?,
        injectPressureAtCheckpoint: Int?,
        preserveCAFWithoutCheckpoint: Bool
    ) async throws -> PairedLaneResult {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let notes = try NoteStore(root: root.appendingPathComponent("notes", isDirectory: true))
        let checkpoints = CheckpointFiles(notes: notes)
        let provenance = ProvenanceFiles(notes: notes)
        let budget = NativeBudget()
        let cap = WhistleCapability(arm64: true, operatingSystemSupported: true, bundleVerified: true,
                                    pipelineAccepted: true, deviceAccepted: true)

        let recordingNotes = CountingRecordingNotes(store: notes)
        let handoff = FakeRecordingHandoff()
        let clock = SystemClock()
        let suite = "io.codemyriad.cassini.qual.whistle.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, clock: clock, defaultLanguage: "en-US")
        settings.recordConsent()
        settings.transcriptionMode = precomputePrefixSeconds == nil ? TranscriptionMode.afterStop : .transcribeWhileRecording

        let prefixPCM: Data? = precomputePrefixSeconds.map { fullPCM.prefix(min(fullPCM.count, $0 * 48_000 * 2)) }
        let fileCapture = QualFileCapture(prefixPCM: prefixPCM, fullPCM: fullPCM)
        let audioProcessor: any AudioProcessing = preserveCAFWithoutCheckpoint ? NoCompressAudioProcessing() : LocalAudioProcessing()

        var precomputeSaved = 0
        var precomputeTelemetry: TelemetrySnapshot?
        let savedCounter = Mutex(0)
        let pressureInjected = Mutex(false)
        let countAtInjection = Mutex<Int?>(nil)
        let thermalInjected = Mutex(ProcessInfo.ThermalState.nominal)
        let activeInjected = Mutex(true)

        let precomputer: CAFPrefixPrecomputer? = precomputePrefixSeconds == nil ? nil : CAFPrefixPrecomputer(
            checkpoints: checkpoints,
            budget: budget,
            mode: { .transcribeWhileRecording },
            engine: { .whistle(.init(acceptance: { cap }, bundle: .main)) },
            pressure: PrecomputePressure(
                isAppActive: { activeInjected.withLock { $0 } },
                thermalState: { thermalInjected.withLock { $0 } }
            ),
            onCheckpointSaved: { _, cp in
                guard !cp.segments.isEmpty else { return }
                let n = savedCounter.withLock { $0 += 1; return $0 }
                if let limit = injectPressureAtCheckpoint, n >= limit {
                    let firstTrigger = pressureInjected.withLock { already -> Bool in
                        if already { return false }
                        already = true
                        return true
                    }
                    if firstTrigger {
                        countAtInjection.withLock { $0 = n }
                        thermalInjected.withLock { $0 = .serious }
                        activeInjected.withLock { $0 = false }
                    }
                }
            }
        )
        let bridge: (any RecordingPrecomputing)? = precomputer.map(ControlledPrecomputeBridge.init)

        let controller = RecordingController(parts: .init(
            ready: {},
            notes: recordingNotes,
            capture: fileCapture,
            storage: UnlimitedStorage(),
            audio: audioProcessor,
            settings: settings,
            handoff: handoff,
            consent: ModelConsent { _, _ in true },
            clock: clock,
            defaultTitle: { _ in "Whistle Paired" },
            precompute: bridge
        ))

        XCTAssertTrue(controller.start())
        let active = try await waitForActiveRecording(controller: controller, timeout: .seconds(15))
        let noteID = active.noteID
        let fetchedActive = await notes.note(noteID)
        let activeNote = try XCTUnwrap(fetchedActive)
        let cafURL = notes.audioURL(for: activeNote)

        if let precomputer {
            let preMon = HandsetTelemetryMonitor.start()
            await precomputer.runOnce(noteID: noteID, captureURL: cafURL)
            precomputeTelemetry = preMon.finish()
            precomputeSaved = savedCounter.withLock { $0 }
            if let limit = injectPressureAtCheckpoint {
                XCTAssertTrue(pressureInjected.withLock { $0 }, "Whistle pressure injection must actually fire during precompute")
                let injectedAt = try XCTUnwrap(countAtInjection.withLock { $0 })
                XCTAssertGreaterThanOrEqual(injectedAt, limit, "Whistle must save at least \(limit) checkpoint(s) before/at pressure injection")
                XCTAssertLessThanOrEqual(precomputeSaved - injectedAt, 1,
                                         "Whistle precompute must pause within 1 segment after pressure injection (saved \(precomputeSaved), injected at \(injectedAt))")
            }
        }

        let postStopSegs = Mutex(0)
        let transcriber = WhistleTranscriber(acceptance: cap)
        let countingTranscriber = CountingTranscriber(inner: transcriber, onSegment: { count in
            postStopSegs.withLock { $0 += count }
        })
        let job = TranscriptionJob(notes: notes, transcriber: countingTranscriber, analyzer: FakeAnalyzer(),
                                   checkpoints: checkpoints, provenance: provenance,
                                   host: StaticJobHost(identifySpeakers: false, voices: []),
                                   clock: clock, budget: budget)

        let postMon = HandsetTelemetryMonitor.start()
        let started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        controller.finish()
        await controller.settle()
        XCTAssertEqual(handoff.handedOff, [noteID])

        let outcome = await job.run(Job(noteID: noteID, seq: 1, kind: .transcribe, state: .running, enqueuedAt: Date()),
                                    stop: StopSignal()) { _ in }
        let elapsed = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - started) / 1_000_000_000.0
        let postSnap = postMon.finish()
        XCTAssertEqual(outcome, JobOutcome.done)

        let fetchedSaved = await notes.note(noteID)
        let saved = try XCTUnwrap(fetchedSaved)
        let finalAudioURL = notes.audioURL(for: saved)
        let exportDir = root.appendingPathComponent("export", isDirectory: true)
        let exporter = PortableExportService(audio: LocalAudioProcessing(), provenance: provenance, unassignedLabel: "Unassigned")
        let opusURL = try await exporter.export(saved, original: finalAudioURL, playable: finalAudioURL, into: exportDir, filename: "published")

        let doc = CassiniDocument.read(opusURL)
        // Ogg Opus headers include a per-encode random serial number, so compare the decoded PCM payload digest & duration.
        let decodedOpusCAF = root.appendingPathComponent("decoded-opus.caf")
        try OpusAudio.decode(opusURL, to: decodedOpusCAF)
        let decodedFile = try AVAudioFile(forReading: decodedOpusCAF)
        let exportedDuration = Double(decodedFile.length) / decodedFile.fileFormat.sampleRate
        let opusSha = SHA256.hash(data: try Data(contentsOf: decodedOpusCAF)).map { String(format: "%02x", $0) }.joined()
        try? FileManager.default.removeItem(at: decodedOpusCAF)
        let words = saved.transcript.flatMap { seg in
            seg.draftWords.map { ComparableWord(text: $0.text, startMs: $0.startMs, endMs: $0.endMs, speaker: nil) }
        }
        return PairedLaneResult(
            audioFilename: saved.audioFilename,
            exportVerified: doc.state == DocumentState.ok,
            exportedDurationSeconds: exportedDuration,
            opusSha256: opusSha,
            words: words,
            speakerTurns: [],
            speakerCount: 0,
            matchedVoiceNames: [],
            precomputeCheckpointsSaved: precomputeSaved,
            postStopWindowsDecoded: 0,
            postStopSegmentsDecoded: postStopSegs.withLock { $0 },
            stopToPublishedSeconds: elapsed,
            telemetry: postSnap,
            precomputeTelemetry: precomputeTelemetry
        )
    }

    // MARK: - Model Installation & Audio Helpers

    private static func ensurePinnedModelsInstalled(in workDir: URL) async throws -> URL {
        // Cache models under Library/Caches so multiple test methods in one Device Farm run download once.
        let cacheRoot = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CassiniQualModels", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        if ModelCatalog.parakeet.ready(in: cacheRoot),
           ModelCatalog.vad.ready(in: cacheRoot),
           ModelCatalog.diarization.ready(in: cacheRoot),
           ModelCatalog.voiceprint.ready(in: cacheRoot) {
            return cacheRoot
        }
        let defaults = UserDefaults(suiteName: "io.codemyriad.cassini.qual.\(UUID().uuidString)")!
        defaults.set(NSNumber(value: Int64((Date().timeIntervalSince1970 * 1000).rounded())), forKey: SettingsKeys.modelsConsentAt)
        let pinned = PinnedModels(root: cacheRoot, defaults: defaults, storage: UnlimitedStorage())
        _ = try await pinned.installer.install([.speech, .speakers, .voices], granted: true) { _ in }
        XCTAssertTrue(ModelCatalog.parakeet.ready(in: cacheRoot))
        XCTAssertTrue(ModelCatalog.diarization.ready(in: cacheRoot))
        XCTAssertTrue(ModelCatalog.voiceprint.ready(in: cacheRoot))
        return cacheRoot
    }

    /// Builds a 48 kHz mono PCM16LE speech track of `totalSeconds` from bundled `WhistleTests/jfk.wav`
    /// with 3 distinct speaker pitch/speed profiles (A: 1.00x, B: 0.86x, C: 1.16x) separated by 0.6 s silence.
    private static func makeMultiSpeakerSpeech48kPCM16LE(totalSeconds: Int) throws -> (Data, [[Float]]) {
        let jfkURL = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("WhistleTests/jfk.wav"),
                                   "WhistleTests/jfk.wav must be bundled in Cassini.app")
        let base16k = try readMono16k(jfkURL)
        let ratios: [Double] = [1.0, 0.86, 1.16]
        let voices16k: [[Float]] = ratios.map { resampleLinear(base16k, factor: $0) }
        let voices48k: [[Float]] = voices16k.map { resampleLinear($0, factor: 3.0) }
        let gap48k = [Float](repeating: 0, count: Int(0.6 * 48_000))

        let targetFrames = totalSeconds * 48_000
        var pcm = Data(capacity: targetFrames * 2)
        var framesWritten = 0
        var speakerIdx = 0
        while framesWritten < targetFrames {
            let clip = voices48k[speakerIdx % voices48k.count]
            let take = min(clip.count, targetFrames - framesWritten)
            appendFloatsAsPCM16LE(&pcm, clip[0..<take])
            framesWritten += take
            if framesWritten < targetFrames {
                let gapTake = min(gap48k.count, targetFrames - framesWritten)
                appendFloatsAsPCM16LE(&pcm, gap48k[0..<gapTake])
                framesWritten += gapTake
            }
            speakerIdx += 1
        }
        return (pcm, voices16k)
    }

    /// Builds a single bounded repeating cycle (~35 s / ~3.3 MiB) of 48 kHz mono PCM16LE multi-speaker speech
    /// for chunked streaming in long-duration qualification runs.
    private static func makeMultiSpeakerSpeechCycle48kPCM16LE() throws -> Data {
        let jfkURL = try XCTUnwrap(Bundle.main.resourceURL?.appendingPathComponent("WhistleTests/jfk.wav"),
                                   "WhistleTests/jfk.wav must be bundled in Cassini.app")
        let base16k = try readMono16k(jfkURL)
        let ratios: [Double] = [1.0, 0.86, 1.16]
        let voices48k: [[Float]] = ratios.map { resampleLinear(resampleLinear(base16k, factor: $0), factor: 3.0) }
        let gap48k = [Float](repeating: 0, count: Int(0.6 * 48_000))
        let totalFrames = voices48k.reduce(0) { $0 + $1.count + gap48k.count }
        var cycle = Data(capacity: totalFrames * 2)
        for clip in voices48k {
            appendFloatsAsPCM16LE(&cycle, clip[0..<clip.count])
            appendFloatsAsPCM16LE(&cycle, gap48k[0..<gap48k.count])
        }
        return cycle
    }

    private static func extractEnrolledVoices(campplusURL: URL, speakerSamples16k: [[Float]]) throws -> [SavedVoice] {
        let names = ["Alice", "Bruno", "Carla"]
        var voices: [SavedVoice] = []
        for (idx, samples) in speakerSamples16k.prefix(3).enumerated() {
            let windows: [String: [PrintWindow]] = ["S": [PrintWindow(0, samples.count)]]
            let prints = try VoiceprintExtractor.compute(model: campplusURL, audio: PcmAudio(samples, sampleRate: 16_000), windows: windows) {}
            if let print = prints["S"] {
                let sp = SpeakerPrint(speakerID: "S\(idx)", model: VoiceprintModel.sha256, vector: print.vector,
                                      speechSeconds: Double(samples.count) / 16_000.0)
                voices.append(SavedVoice(id: UUID(), name: names[idx], samples: [VoiceSample(noteID: UUID(), print: sp)]))
            }
        }
        return voices
    }

    private static func readMono16k(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let converter = try XCTUnwrap(AVAudioConverter(from: file.processingFormat, to: format))
        var out: [Float] = []
        let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 16_384))
        let output = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384))
        while true {
            var done = false
            var err: NSError?
            let status = converter.convert(to: output, error: &err) { _, status in
                do {
                    try file.read(into: input)
                    if input.frameLength == 0 { done = true; status.pointee = .endOfStream; return nil }
                    status.pointee = .haveData; return input
                } catch {
                    done = true; status.pointee = .endOfStream; return nil
                }
            }
            if let err { throw err }
            if output.frameLength > 0 {
                out.append(contentsOf: UnsafeBufferPointer(start: output.floatChannelData![0], count: Int(output.frameLength)))
            }
            if status == .endOfStream || done { break }
        }
        return out
    }

    private static func resampleLinear(_ samples: [Float], factor: Double) -> [Float] {
        guard !samples.isEmpty, factor > 0 else { return [] }
        let outCount = Int((Double(samples.count) * factor).rounded())
        var out = [Float](repeating: 0, count: outCount)
        let step = 1.0 / factor
        for i in 0..<outCount {
            let pos = Double(i) * step
            let idx = Int(pos)
            let frac = Float(pos - Double(idx))
            let a = samples[min(idx, samples.count - 1)]
            let b = samples[min(idx + 1, samples.count - 1)]
            out[i] = a + (b - a) * frac
        }
        return out
    }

    private static func appendFloatsAsPCM16LE(_ data: inout Data, _ slice: ArraySlice<Float>) {
        for sample in slice {
            let scaled = max(-32768.0, min(32767.0, Double(sample) * 32768.0))
            var i16 = Int16(scaled.rounded()).littleEndian
            withUnsafeBytes(of: &i16) { data.append(contentsOf: $0) }
        }
    }

    private static func makeTonePCM16LE(seconds: Int, sampleRate: Int) -> Data {
        var data = Data(capacity: seconds * sampleRate * 2)
        for i in 0..<(seconds * sampleRate) {
            let s = sin(2.0 * .pi * 440.0 * Double(i) / Double(sampleRate)) * 0.25
            var i16 = Int16((s * 32767.0).rounded()).littleEndian
            withUnsafeBytes(of: &i16) { data.append(contentsOf: $0) }
        }
        return data
    }

    private static func writeCAF(to url: URL, sampleRate: Double, pcm: Data, finalized: Bool) throws {
        var out = Data()
        out.append(contentsOf: "caff".utf8)
        out.append(contentsOf: [0, 1, 0, 0])
        out.append(contentsOf: "desc".utf8)
        appendBE(&out, Int64(32))
        appendBE(&out, sampleRate.bitPattern)
        out.append(contentsOf: "lpcm".utf8)
        appendBE(&out, UInt32(2))
        appendBE(&out, UInt32(2))
        appendBE(&out, UInt32(1))
        appendBE(&out, UInt32(1))
        appendBE(&out, UInt32(16))
        out.append(contentsOf: "data".utf8)
        appendBE(&out, finalized ? Int64(pcm.count + 4) : Int64(-1))
        appendBE(&out, UInt32(0))
        out.append(pcm)
        try out.write(to: url)
    }

    private static func finalizeCAFHeader(at url: URL, pcmBytes: UInt64) throws {
        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        // In our writeCAF layout: caff(8) + desc(12+32=44) + "data"(4) = offset 56 is the Int64 data chunk size.
        try handle.seek(toOffset: 56)
        var sizeBE = Int64(pcmBytes + 4).bigEndian
        let bytes = withUnsafeBytes(of: &sizeBE) { Data($0) }
        try handle.write(contentsOf: bytes)
        try handle.synchronize()
    }

    private static func appendBE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        var be = value.bigEndian
        withUnsafeBytes(of: &be) { data.append(contentsOf: $0) }
    }

    private static func asDictionary<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func emitReport(name: String, report: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return }
        print("CASSINI_HANDSET_QUAL_BEGIN:\(name)\n\(text)\nCASSINI_HANDSET_QUAL_END:\(name)")
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
        attachment.name = "\(name).json"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Event-Gated Waiters & Local Test Support Doubles

    private struct TimeoutError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Event-driven observer for `AVCaptureAdapter.events` with bounded failure timeouts (zero fixed sleeps).
    private final class CaptureEventGate: @unchecked Sendable {
        private struct State {
            var observed: [String] = []
            var waiters: [(id: UUID, name: String, count: Int, continuation: CheckedContinuation<Void, any Error>)] = []
        }

        private let state = Mutex(State())
        private var task: Task<Void, Never>?

        init(stream: AsyncStream<CaptureEvent>) {
            task = Task { [weak self] in
                for await ev in stream {
                    guard let self else { return }
                    let label: String? = switch ev {
                    case .interrupted: "interrupted"
                    case .routeLost: "routeLost"
                    case .failed: "failed"
                    case .mediaReset: "mediaReset"
                    case .level: nil
                    }
                    guard let label else { continue }
                    let ready: [CheckedContinuation<Void, any Error>] = self.state.withLock { s in
                        s.observed.append(label)
                        var matched: [CheckedContinuation<Void, any Error>] = []
                        s.waiters.removeAll { waiter in
                            let seen = s.observed.filter { $0 == waiter.name }.count
                            if seen >= waiter.count {
                                matched.append(waiter.continuation)
                                return true
                            }
                            return false
                        }
                        return matched
                    }
                    for cont in ready { cont.resume() }
                }
            }
        }

        var observedEvents: [String] { state.withLock { $0.observed } }

        func cancel() {
            task?.cancel()
            task = nil
            let pending = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
                let list = s.waiters.map(\.continuation)
                s.waiters.removeAll()
                return list
            }
            for cont in pending { cont.resume(throwing: CancellationError()) }
        }

        func waitFor(_ name: String, count: Int, timeout: Duration) async throws {
            let waiterID = UUID()
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard !Task.isCancelled, let self else { return }
                let expired = self.state.withLock { s -> CheckedContinuation<Void, any Error>? in
                    guard let idx = s.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                    return s.waiters.remove(at: idx).continuation
                }
                expired?.resume(throwing: TimeoutError(message: "Timed out after \(timeout) waiting for capture event '\(name)' (count >= \(count))"))
            }
            defer { timeoutTask.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let alreadySatisfied = state.withLock { s -> Bool in
                    if s.observed.filter({ $0 == name }).count >= count { return true }
                    s.waiters.append((waiterID, name, count, continuation))
                    return false
                }
                if alreadySatisfied { continuation.resume() }
            }
        }
    }

    @MainActor
    private func waitForLiveCAFReader(at url: URL, timeout: Duration) async throws -> LiveCAFReader {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let reader = try? LiveCAFReader(url: url) { return reader }
            if ContinuousClock.now >= deadline {
                throw TimeoutError(message: "Timed out after \(timeout) waiting for LiveCAFReader to open \(url.lastPathComponent)")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor
    private func waitForCAFSafeFrames(
        reader: LiveCAFReader,
        atLeast targetFrames: UInt64,
        timeout: Duration,
        description: String
    ) async throws -> UInt64 {
        let deadline = ContinuousClock.now + timeout
        while true {
            let safe = (try? reader.safeThroughFrame(safetyMarginFrames: LiveCAFReader.defaultSafetyMarginFrames)) ?? 0
            if safe >= targetFrames { return safe }
            if ContinuousClock.now >= deadline {
                throw TimeoutError(message: "Timed out after \(timeout) waiting for \(description): reached \(safe) / \(targetFrames) frames")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    @MainActor
    private func waitForActiveRecording(controller: RecordingController, timeout: Duration) async throws -> ActiveRecording {
        let deadline = ContinuousClock.now + timeout
        while true {
            if let active = controller.state.activeRecording { return active }
            if ContinuousClock.now >= deadline {
                throw TimeoutError(message: "Timed out after \(timeout) waiting for RecordingController to become active (state: \(controller.state))")
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func wordErrorRate(reference: [ComparableWord], hypothesis: [ComparableWord]) -> Double {
        let ref = reference.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        let hyp = hypothesis.map { $0.text.lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { !$0.isEmpty }
        guard !ref.isEmpty else { return hyp.isEmpty ? 0.0 : 1.0 }
        guard !hyp.isEmpty else { return 1.0 }
        var prev = Array(0...hyp.count)
        var curr = Array(repeating: 0, count: hyp.count + 1)
        for i in 1...ref.count {
            curr[0] = i
            for j in 1...hyp.count {
                let cost = ref[i - 1] == hyp[j - 1] ? 0 : 1
                curr[j] = min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
            }
            swap(&prev, &curr)
        }
        return Double(prev[hyp.count]) / Double(ref.count)
    }

    @MainActor
    private final class QualFileCapture: AudioCapture {
        let events: AsyncStream<CaptureEvent>
        private let continuation: AsyncStream<CaptureEvent>.Continuation
        var elapsed: TimeInterval = 0
        private(set) var recordedAt: Date?
        private var captureURL: URL?
        private let prefixPCM: Data?
        private let fullPCM: Data
        private let fullDuration: TimeInterval

        init(prefixPCM: Data?, fullPCM: Data, sampleRate: Double = 48_000) {
            (events, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
            self.prefixPCM = prefixPCM
            self.fullPCM = fullPCM
            self.fullDuration = Double(fullPCM.count / 2) / sampleRate
        }

        var fileBytes: Int64 {
            guard let url = captureURL else { return 0 }
            return Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }

        func start(url: URL) async throws -> CaptureFormat {
            self.captureURL = url
            self.recordedAt = Date()
            let initial = prefixPCM ?? fullPCM
            try HandsetQualificationTests.writeCAF(to: url, sampleRate: 48_000, pcm: initial, finalized: false)
            self.elapsed = Double(initial.count / 2) / 48_000.0
            return .pcm48kMono
        }

        func pause() {}
        func resume() throws {}

        func stop() async throws -> CaptureResult {
            if let url = captureURL {
                try HandsetQualificationTests.writeCAF(to: url, sampleRate: 48_000, pcm: fullPCM, finalized: true)
            }
            self.elapsed = fullDuration
            return CaptureResult(duration: fullDuration)
        }
    }

    private final class ControlledPrecomputeBridge: RecordingPrecomputing, @unchecked Sendable {
        let inner: CAFPrefixPrecomputer
        init(inner: CAFPrefixPrecomputer) { self.inner = inner }
        func start(noteID: UUID, captureURL: URL) {}
        func stop(noteID: UUID) async { await inner.stop(noteID: noteID) }
        func preempt() async { await inner.preempt() }
        func hasPrecomputeCheckpoint(for noteID: UUID) -> Bool {
            inner.hasPrecomputeCheckpoint(for: noteID)
        }
    }

    private final class StaticCheckpointPrecompute: RecordingPrecomputing, @unchecked Sendable {
        func start(noteID: UUID, captureURL: URL) {}
        func stop(noteID: UUID) async {}
        func preempt() async {}
        func hasPrecomputeCheckpoint(for noteID: UUID) -> Bool { true }
    }

    private final class SpyPrecompute: RecordingPrecomputing, @unchecked Sendable {
        private let starts = Mutex(0)
        var startCount: Int { starts.withLock { $0 } }
        func start(noteID: UUID, captureURL: URL) { starts.withLock { $0 += 1 } }
        func stop(noteID: UUID) async {}
        func preempt() async {}
        func hasPrecomputeCheckpoint(for noteID: UUID) -> Bool { false }
    }

    /// Exercises `RecordingController.finishAudio`'s fallback to preserving `capture.caf` when M4A compression is skipped,
    /// allowing an identical-CAF `afterStop` control alongside the production M4A `afterStop` lane.
    private struct NoCompressAudioProcessing: AudioProcessing {
        private let base = LocalAudioProcessing()
        func inspect(_ url: URL) async throws -> AudioSummary { try await base.inspect(url) }
        func compress(_ source: URL, to destination: URL) async throws { throw AudioError.unreadable }
        func decodeOpus(_ source: URL, to destination: URL) async throws { try await base.decodeOpus(source, to: destination) }
        func encodeOpus(_ source: URL, to destination: URL) async throws { try await base.encodeOpus(source, to: destination) }
    }

    private struct AlwaysConsent: ModelConsentRecords {
        func consentAt() async -> Date? { Date(timeIntervalSince1970: 1) }
        func recordConsent() async {}
        func recordDeclined() async {}
    }

    private struct UnlimitedStorage: StorageProbe {
        func availableBytes(at url: URL) -> Int64 { 64 << 30 }
    }

    private struct UnavailableFetcher: ModelFetching {
        func fetch(_ model: ModelDescriptor, into directory: URL,
                   progress: @escaping @Sendable (Int64, Bool) -> Void) async throws {
            throw NSError(domain: "Qual", code: 1)
        }
    }

    private struct StaticJobHost: TranscriptionJobHost {
        let identifySpeakers: Bool
        let voices: [SavedVoice]
        func jobSettings() async -> JobSettings {
            JobSettings(allowSpeechDownload: false, identifySpeakers: identifySpeakers, allowSpeakerDownload: false,
                        voicesGeneration: 0, automaticallyNameVoices: true)
        }
        func liveVoices(generation: Int) async -> @Sendable () -> [SavedVoice] { { voices } }
        func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws {}
    }

    private final class MatchingJobHost: TranscriptionJobHost, @unchecked Sendable {
        let notes: NoteStore
        let voices: [SavedVoice]
        private let matched = Mutex<[String]>([])
        var matchedNames: [String] { matched.withLock { $0 } }

        init(notes: NoteStore, voices: [SavedVoice]) {
            self.notes = notes
            self.voices = voices
        }

        func jobSettings() async -> JobSettings {
            JobSettings(allowSpeechDownload: false, identifySpeakers: true, allowSpeakerDownload: false,
                        voicesGeneration: 0, automaticallyNameVoices: true)
        }

        func liveVoices(generation: Int) async -> @Sendable () -> [SavedVoice] { { [voices] in voices } }

        func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws {
            guard var note = await notes.note(noteID) else { return }
            let matching = AnalysisMatches.of(note, turns: analysis.turns, prints: analysis.prints,
                                              savedVoices: voices, earlierPrints: [], trashed: [], excluded: [:])
            let names = matching.matches.values.compactMap { m in voices.first { $0.id == m.voiceID }?.name }
            matched.withLock { $0 = names }
            matching.apply(to: &note, turns: analysis.turns, autoName: true, stamp: VersionStamp(date: Date()),
                           attributed: analysis.transcript, excluded: [:], labels: [:], colourIndices: [:], explicitNames: [])
            try await notes.save(note)
        }
    }

    private struct CountingTranscriber: Transcribing {
        let inner: WhistleTranscriber
        let onSegment: @Sendable (Int) -> Void
        var recognizer: SpeechRecognizer { inner.recognizer }
        var assetInstallBytes: Int64 { inner.assetInstallBytes }
        func forJob(recognizer: String?) throws -> any Transcribing { self }
        func segmentation() async -> String? { await inner.segmentation() }
        func assetStatus(locale: Locale) async -> ModelPartStatus { await inner.assetStatus(locale: locale) }
        func availability(locale: Locale) async -> SpeechAvailability { await inner.availability(locale: locale) }
        func unavailability(locale: Locale) async -> JobFailure? { await inner.unavailability(locale: locale) }
        func installAssets(locale: Locale, progress: @escaping @Sendable (InstallProgress) -> Void) async throws {
            try await inner.installAssets(locale: locale, progress: progress)
        }
        func speechLanguages() async -> [SpeechLanguage] { await inner.speechLanguages() }
        func modelName(locale: Locale) async -> String? { await inner.modelName(locale: locale) }
        func runLanguage(requested: String) async -> String? { await inner.runLanguage(requested: requested) }
        func transcribe(_ request: TranscriptionRequest,
                        events: @escaping @Sendable (TranscriptionEvent) -> Void) async throws -> TranscriptionResult {
            try await inner.transcribe(request) { event in
                if case .whistleBatch(let batch) = event, !batch.segments.isEmpty {
                    onSegment(batch.segments.count)
                }
                events(event)
            }
        }
    }
}
