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

        let liveReader = try await BackgroundCAFReader.open(at: growingURL)
        let finalReader = try await BackgroundCAFReader.open(at: finalURL)

        let prefixFrames: UInt64 = 2 * 48_000 + 48
        let liveHash = try await liveReader.prefixSHA256(committedFrames: prefixFrames)
        let finalHash = try await finalReader.prefixSHA256(committedFrames: prefixFrames)
        await liveReader.close()
        await finalReader.close()
        XCTAssertEqual(liveHash, finalHash)

        // 3. Simulated AVAudioSession interruption & route-change hooks on AVCaptureAdapter.
        let recordGate = CountGate()
        final class FakeCaptureRecorder: CaptureRecorder {
            var delegate: (any AVAudioRecorderDelegate)?
            var isMeteringEnabled = false
            var currentTime: TimeInterval = 1.5
            let url: URL
            let onRecord: () -> Void
            var pauseCount = 0
            var stopCount = 0
            init(url: URL, onRecord: @escaping () -> Void) {
                self.url = url
                self.onRecord = onRecord
            }
            func record() -> Bool {
                onRecord()
                return true
            }
            func pause() { pauseCount += 1 }
            func stop() { stopCount += 1 }
            func updateMeters() {}
            func averagePower(forChannel channelNumber: Int) -> Float { -12 }
        }
        let fakeRec = FakeCaptureRecorder(url: finalURL, onRecord: { recordGate.signal() })
        let session = CaptureSession(requestPermission: { true }, prepare: {}, activate: {}, deactivate: {})
        let adapter = AVCaptureAdapter(session: session, makeRecorder: { _ in fakeRec })
        _ = try await adapter.start(url: finalURL)
        try await recordGate.waitFor(count: 1, timeout: .seconds(5))

        let eventGate = CaptureEventGate(stream: adapter.events)
        defer { eventGate.cancel() }
        NotificationCenter.default.post(
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
        )
        try await eventGate.waitFor("interrupted", count: 1, timeout: .seconds(5))
        try adapter.resume()
        try await recordGate.waitFor(count: 2, timeout: .seconds(5))
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        try await eventGate.waitFor("routeLost", count: 1, timeout: .seconds(5))
        _ = try await adapter.stop()
        XCTAssertEqual(eventGate.observedEvents, ["interrupted", "routeLost"])
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

    func testCanonicalSpeakerSlotAndVoiceMapComparison() {
        let prefixA = WindowSpeakers.freshPrefix()
        let prefixB = WindowSpeakers.freshPrefix()
        XCTAssertNotEqual(prefixA, prefixB)

        let rawTurnsA = [
            DiarizerTurn(0, 2_000, 0).speakerTurn(prefix: prefixA),
            DiarizerTurn(2_500, 5_000, 2).speakerTurn(prefix: prefixA)
        ]
        let rawTurnsB = [
            DiarizerTurn(0, 2_000, 0).speakerTurn(prefix: prefixB),
            DiarizerTurn(2_500, 5_000, 2).speakerTurn(prefix: prefixB)
        ]
        XCTAssertEqual(Self.canonicalizeSpeakerTurns(rawTurnsA), Self.canonicalizeSpeakerTurns(rawTurnsB))

        let shiftedTurns = [
            DiarizerTurn(0, 2_100, 0).speakerTurn(prefix: prefixB),
            DiarizerTurn(2_500, 5_000, 2).speakerTurn(prefix: prefixB)
        ]
        XCTAssertNotEqual(Self.canonicalizeSpeakerTurns(rawTurnsA), Self.canonicalizeSpeakerTurns(shiftedTurns))

        let voicesA = ["\(prefixA)1": "Alice", "\(prefixA)3": "Carla"]
        let voicesB = ["\(prefixB)1": "Alice", "\(prefixB)3": "Carla"]
        let swappedVoices = ["\(prefixB)1": "Carla", "\(prefixB)3": "Alice"]
        XCTAssertEqual(Self.canonicalizeVoiceMap(voicesA), Self.canonicalizeVoiceMap(voicesB))
        XCTAssertEqual(Self.canonicalizeVoiceMap(voicesA), ["1": "Alice", "3": "Carla"])
        XCTAssertNotEqual(Self.canonicalizeVoiceMap(voicesA), Self.canonicalizeVoiceMap(swappedVoices))
        XCTAssertEqual(Self.canonicalSpeakerSlot("S1"), "S1")
    }

    @MainActor
    func testPairedEvaluationRejectsSwappedVoicesAndProvenanceMismatch() {
        let snap = HandsetTelemetryMonitor.start().finish()
        let baseProv = JSONObject([
            ("engine", .string(TranscriptProvenance.parakeetEngine)),
            ("backend", .string(TranscriptProvenance.sherpaBackend)),
            ("language", .string("und"))
        ])
        let words = [ComparableWord(text: "hello", startMs: 0, endMs: 500, speaker: "S1")]
        let turns = [
            ComparableTurn(speaker: "1", startMs: 0, endMs: 1_000),
            ComparableTurn(speaker: "2", startMs: 1_500, endMs: 2_500),
            ComparableTurn(speaker: "3", startMs: 3_000, endMs: 4_000)
        ]
        func makeLane(
            audioFilename: String = RecordingController.captureFilename,
            words: [ComparableWord] = words,
            matchedVoicesBySpeaker: [String: String] = ["1": "Alice", "3": "Carla"],
            speechProvenance: JSONObject? = baseProv,
            precomputeCheckpointsSaved: Int = 2,
            checkpointsAtPressureInjection: Int? = nil,
            postStopWindowsDecoded: Int = 1,
            postStopSegmentsDecoded: Int = 0
        ) -> PairedLaneResult {
            PairedLaneResult(
                audioFilename: audioFilename,
                exportVerified: true,
                speechProvenance: speechProvenance,
                exportedDurationSeconds: 10.0,
                opusSha256: "abc123",
                words: words,
                speakerTurns: turns,
                speakerCount: 3,
                matchedVoiceNames: ["Alice", "Carla"],
                matchedVoicesBySpeaker: matchedVoicesBySpeaker,
                precomputeCheckpointsSaved: precomputeCheckpointsSaved,
                checkpointsAtPressureInjection: checkpointsAtPressureInjection,
                postStopWindowsDecoded: postStopWindowsDecoded,
                postStopSegmentsDecoded: postStopSegmentsDecoded,
                stopToPublishedSeconds: 1.0,
                telemetry: snap,
                precomputeTelemetry: nil
            )
        }

        let baseline = makeLane(audioFilename: RecordingController.compressedFilename, precomputeCheckpointsSaved: 0, postStopWindowsDecoded: 4)
        let control = makeLane(precomputeCheckpointsSaved: 0, postStopWindowsDecoded: 4)
        let headStart = makeLane(precomputeCheckpointsSaved: 3, postStopWindowsDecoded: 1)
        let pressure = makeLane(precomputeCheckpointsSaved: 3, checkpointsAtPressureInjection: 2, postStopWindowsDecoded: 2)

        let passing = Self.evaluateParakeetPaired(baseline: baseline, cafControl: control, headStart: headStart, pressure: pressure)
        XCTAssertTrue(passing.equivalencePassed)
        XCTAssertTrue(passing.pressureRecoveryPassed)

        // Swapping Alice and Carla across slots while keeping matchedVoiceNames == ["Alice", "Carla"] must fail equivalence.
        let swappedHeadStart = makeLane(matchedVoicesBySpeaker: ["1": "Carla", "3": "Alice"], precomputeCheckpointsSaved: 3, postStopWindowsDecoded: 1)
        let swappedEval = Self.evaluateParakeetPaired(baseline: baseline, cafControl: control, headStart: swappedHeadStart, pressure: pressure)
        XCTAssertFalse(swappedEval.equivalencePassed, "Swapped speaker-to-voice assignment must set equivalencePassed = false")
        XCTAssertTrue(swappedEval.pressureRecoveryPassed)

        // Mismatched deterministic provenance on the pressure lane must fail pressureRecoveryPassed.
        let wrongProv = JSONObject([
            ("engine", .string(TranscriptProvenance.parakeetEngine)),
            ("backend", .string("other-backend")),
            ("language", .string("und"))
        ])
        let badProvPressure = makeLane(speechProvenance: wrongProv, precomputeCheckpointsSaved: 3, checkpointsAtPressureInjection: 2, postStopWindowsDecoded: 2)
        let badProvEval = Self.evaluateParakeetPaired(baseline: baseline, cafControl: control, headStart: headStart, pressure: badProvPressure)
        XCTAssertTrue(badProvEval.equivalencePassed)
        XCTAssertFalse(badProvEval.pressureRecoveryPassed, "Provenance mismatch must set pressureRecoveryPassed = false")

        // Parakeet: matching output with two extra checkpoints after pressure injection must fail pressureRecoveryPassed.
        let parakeetIgnoredPressure = makeLane(precomputeCheckpointsSaved: 4, checkpointsAtPressureInjection: 2, postStopWindowsDecoded: 1)
        let parakeetIgnoredEval = Self.evaluateParakeetPaired(baseline: baseline, cafControl: control, headStart: headStart, pressure: parakeetIgnoredPressure)
        XCTAssertTrue(parakeetIgnoredEval.equivalencePassed)
        XCTAssertFalse(parakeetIgnoredEval.pressureRecoveryPassed, "Parakeet ignoring pressure (>1 extra checkpoint) must set pressureRecoveryPassed = false")

        // Whistle: matching output with <=1 extra checkpoint passes; two extra checkpoints after pressure injection must fail pressureRecoveryPassed.
        let whistleProv = JSONObject([
            ("engine", .string("Whistle")),
            ("backend", .string("Needle C API (CPU, on-device)")),
            ("language", .string("en"))
        ])
        let whistleBaseline = makeLane(audioFilename: RecordingController.compressedFilename, speechProvenance: whistleProv, precomputeCheckpointsSaved: 0, postStopWindowsDecoded: 0, postStopSegmentsDecoded: 20)
        let whistleControl = makeLane(speechProvenance: whistleProv, precomputeCheckpointsSaved: 0, postStopWindowsDecoded: 0, postStopSegmentsDecoded: 20)
        let whistleHeadStart = makeLane(speechProvenance: whistleProv, precomputeCheckpointsSaved: 10, postStopWindowsDecoded: 0, postStopSegmentsDecoded: 3)
        let whistlePressure = makeLane(speechProvenance: whistleProv, precomputeCheckpointsSaved: 4, checkpointsAtPressureInjection: 3, postStopWindowsDecoded: 0, postStopSegmentsDecoded: 12)
        let whistlePassing = Self.evaluateWhistlePaired(baseline: whistleBaseline, cafControl: whistleControl, headStart: whistleHeadStart, pressure: whistlePressure)
        XCTAssertTrue(whistlePassing.equivalencePassed)
        XCTAssertTrue(whistlePassing.pressureRecoveryPassed)

        let whistleIgnoredPressure = makeLane(speechProvenance: whistleProv, precomputeCheckpointsSaved: 5, checkpointsAtPressureInjection: 3, postStopWindowsDecoded: 0, postStopSegmentsDecoded: 10)
        let whistleIgnoredEval = Self.evaluateWhistlePaired(baseline: whistleBaseline, cafControl: whistleControl, headStart: whistleHeadStart, pressure: whistleIgnoredPressure)
        XCTAssertTrue(whistleIgnoredEval.equivalencePassed)
        XCTAssertFalse(whistleIgnoredEval.pressureRecoveryPassed, "Whistle ignoring pressure (>1 extra checkpoint) must set pressureRecoveryPassed = false")

        // Whistle & Parakeet: segments with non-empty text but empty `seg.words` (missing word timings)
        // must extract to zero timed words and fail both equivalencePassed and pressureRecoveryPassed.
        let untimedSegment = TranscriptSegment(text: "hello world without word timings", start: 0, end: 2.0, speaker: "Alice", words: [])
        let extractedWhistleUntimed = Self.extractComparableWords(from: [untimedSegment], includeSpeaker: false)
        let extractedParakeetUntimed = Self.extractComparableWords(from: [untimedSegment], includeSpeaker: true)
        XCTAssertTrue(extractedWhistleUntimed.isEmpty, "Missing seg.words must not fall back to draftWords")
        XCTAssertTrue(extractedParakeetUntimed.isEmpty, "Missing seg.words must not fall back to draftWords")

        let whistleEmptyBaseline = makeLane(audioFilename: RecordingController.compressedFilename, words: extractedWhistleUntimed, speechProvenance: whistleProv, precomputeCheckpointsSaved: 0, postStopWindowsDecoded: 0, postStopSegmentsDecoded: 20)
        let whistleEmptyControl = makeLane(words: extractedWhistleUntimed, speechProvenance: whistleProv, precomputeCheckpointsSaved: 0, postStopWindowsDecoded: 0, postStopSegmentsDecoded: 20)
        let whistleEmptyHeadStart = makeLane(words: extractedWhistleUntimed, speechProvenance: whistleProv, precomputeCheckpointsSaved: 10, postStopWindowsDecoded: 0, postStopSegmentsDecoded: 3)
        let whistleEmptyPressure = makeLane(words: extractedWhistleUntimed, speechProvenance: whistleProv, precomputeCheckpointsSaved: 4, checkpointsAtPressureInjection: 3, postStopWindowsDecoded: 0, postStopSegmentsDecoded: 12)
        let whistleEmptyEval = Self.evaluateWhistlePaired(
            baseline: whistleEmptyBaseline,
            cafControl: whistleEmptyControl,
            headStart: whistleEmptyHeadStart,
            pressure: whistleEmptyPressure
        )
        XCTAssertFalse(whistleEmptyEval.equivalencePassed, "Whistle untimed/empty transcripts must set equivalencePassed = false")
        XCTAssertFalse(whistleEmptyEval.pressureRecoveryPassed, "Whistle untimed/empty transcripts must set pressureRecoveryPassed = false")

        let parakeetEmptyBaseline = makeLane(audioFilename: RecordingController.compressedFilename, words: extractedParakeetUntimed, precomputeCheckpointsSaved: 0, postStopWindowsDecoded: 4)
        let parakeetEmptyControl = makeLane(words: extractedParakeetUntimed, precomputeCheckpointsSaved: 0, postStopWindowsDecoded: 4)
        let parakeetEmptyHeadStart = makeLane(words: extractedParakeetUntimed, precomputeCheckpointsSaved: 3, postStopWindowsDecoded: 1)
        let parakeetEmptyPressure = makeLane(words: extractedParakeetUntimed, precomputeCheckpointsSaved: 3, checkpointsAtPressureInjection: 2, postStopWindowsDecoded: 2)
        let parakeetEmptyEval = Self.evaluateParakeetPaired(
            baseline: parakeetEmptyBaseline,
            cafControl: parakeetEmptyControl,
            headStart: parakeetEmptyHeadStart,
            pressure: parakeetEmptyPressure
        )
        XCTAssertFalse(parakeetEmptyEval.equivalencePassed, "Parakeet untimed/empty transcripts must set equivalencePassed = false")
        XCTAssertFalse(parakeetEmptyEval.pressureRecoveryPassed, "Parakeet untimed/empty transcripts must set pressureRecoveryPassed = false")
    }

    func testGateImmediateTimeoutDoesNotHang() async {
        let countGate = CountGate()
        for timeout in [Duration.zero, .nanoseconds(1)] {
            do {
                try await countGate.waitFor(count: 1, timeout: timeout)
                XCTFail("Unsignaled CountGate must time out for \(timeout)")
            } catch is TimeoutError {
                // Expected.
            } catch {
                XCTFail("Unexpected error from CountGate: \(error)")
            }
        }

        let (stream, continuation) = AsyncStream.makeStream(of: CaptureEvent.self)
        let eventGate = CaptureEventGate(stream: stream)
        defer {
            eventGate.cancel()
            continuation.finish()
        }
        for timeout in [Duration.zero, .nanoseconds(1)] {
            do {
                try await eventGate.waitFor("interrupted", count: 1, timeout: timeout)
                XCTFail("Unsignaled CaptureEventGate must time out for \(timeout)")
            } catch is TimeoutError {
                // Expected.
            } catch {
                XCTFail("Unexpected error from CaptureEventGate: \(error)")
            }
        }
    }

    func testLongRunValidatorsRejectDiscardedCheckpointAndEarlyDiarizerFailure() {
        let dummyURL = URL(fileURLWithPath: "/tmp/dummy.caf")
        let freshReq = TranscriptionRequest(url: dummyURL, language: "en-US", allowDownload: false)

        // Discarded checkpoints (zero resume) must fail for both Parakeet and Whistle.
        XCTAssertFalse(Self.validateLongRunCheckpointResume(engine: .parakeet, request: freshReq).isEmpty)
        XCTAssertFalse(Self.validateLongRunCheckpointResume(engine: .whistle, request: freshReq).isEmpty)
        XCTAssertFalse(Self.validateLongRunCheckpointResume(engine: .parakeet, request: nil).isEmpty)

        // Positive resume checkpoints pass for both engines.
        let parakeetResumedReq = TranscriptionRequest(
            url: dummyURL,
            language: "en-US",
            resume: TranscriptResume(recognition: RecognitionCheckpoint(start: 0, end: 160_000, position: 160_000), words: []),
            allowDownload: false
        )
        XCTAssertEqual(Self.validateLongRunCheckpointResume(engine: .parakeet, request: parakeetResumedReq), [])

        let whistleResumedReq = TranscriptionRequest(
            url: dummyURL,
            language: "en-US",
            allowDownload: false,
            whistleResume: WhistleCheckpoint(sourceFrame: 480_000, processedSamples: 160_000, doneSamples: 160_000, state: Data([1]))
        )
        XCTAssertEqual(Self.validateLongRunCheckpointResume(engine: .whistle, request: whistleResumedReq), [])

        // Parakeet 30-min Sortformer continuity: speakerAnalysisFailure, nil analysis, or early-only turns must fail.
        let prefix = WindowSpeakers.freshPrefix()
        let earlyOnly = SpeakerAnalysis(
            turns: [
                DiarizerTurn(0, 10_000, 0).speakerTurn(prefix: prefix),
                DiarizerTurn(11_000, 20_000, 1).speakerTurn(prefix: prefix)
            ],
            prints: []
        )
        XCTAssertFalse(Self.validateLongRunParakeetSpeakers(speakerAnalysisFailure: .speakers, analysis: earlyOnly, totalDurationSeconds: 1800).isEmpty)
        XCTAssertFalse(Self.validateLongRunParakeetSpeakers(speakerAnalysisFailure: nil, analysis: nil, totalDurationSeconds: 1800).isEmpty)
        XCTAssertFalse(Self.validateLongRunParakeetSpeakers(speakerAnalysisFailure: nil, analysis: earlyOnly, totalDurationSeconds: 1800).isEmpty)

        let fullRunSpeakers = SpeakerAnalysis(
            turns: [
                DiarizerTurn(0, 10_000, 0).speakerTurn(prefix: prefix),
                DiarizerTurn(1_500_000, 1_520_000, 0).speakerTurn(prefix: prefix),
                DiarizerTurn(1_530_000, 1_550_000, 2).speakerTurn(prefix: prefix)
            ],
            prints: []
        )
        XCTAssertEqual(Self.validateLongRunParakeetSpeakers(speakerAnalysisFailure: nil, analysis: fullRunSpeakers, totalDurationSeconds: 1800), [])
    }

    @MainActor
    func testContinuousCaptureContinuityRejectsEarlyPause() async throws {
        final class EarlyPauseRecorder: CaptureRecorder {
            var delegate: (any AVAudioRecorderDelegate)?
            var isMeteringEnabled = false
            var currentTime: TimeInterval = 1.5
            let url: URL
            var pauseCount = 0
            init(url: URL) { self.url = url }
            func record() -> Bool { true }
            func pause() { pauseCount += 1 }
            func stop() {}
            func updateMeters() {}
            func averagePower(forChannel channelNumber: Int) -> Float { -12 }
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("qual-continuity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let cafURL = dir.appendingPathComponent("early-pause.caf")

        let fakeRec = EarlyPauseRecorder(url: cafURL)
        let session = CaptureSession(requestPermission: { true }, prepare: {}, activate: {}, deactivate: {})
        let adapter = AVCaptureAdapter(session: session, makeRecorder: { _ in fakeRec })
        _ = try await adapter.start(url: cafURL)

        let eventGate = CaptureEventGate(stream: adapter.events)
        defer { eventGate.cancel() }
        // Simulate an early BT route loss pausing the recorder at 1.5 s while the 30-s capture window continues.
        NotificationCenter.default.post(
            name: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
        )
        try await eventGate.waitFor("routeLost", count: 1, timeout: .seconds(5))
        _ = try await adapter.stop()
        XCTAssertEqual(fakeRec.pauseCount, 1)

        // Even though recorder.currentTime (1.5 s) would match a truncated 1.5 s CAF, comparing against the
        // monotonic interval (30.0 s) and rejecting route-loss events catches the truncated recording.
        let failures = Self.validateContinuousMicCapture(
            recordedDurationSeconds: fakeRec.currentTime,
            monotonicElapsedSeconds: 30.0,
            events: eventGate.observedEvents
        )
        XCTAssertEqual(failures.count, 2, "Must report both unexpected capture event and monotonic duration drift")
        XCTAssertTrue(failures.contains { $0.contains("routeLost") })
        XCTAssertTrue(failures.contains { $0.contains("drifted") })

        // Truncation alone (without an event) also fails against monotonic elapsed time.
        let driftOnly = Self.validateContinuousMicCapture(
            recordedDurationSeconds: 1.5,
            monotonicElapsedSeconds: 30.0,
            events: []
        )
        XCTAssertEqual(driftOnly.count, 1)

        // Uninterrupted continuous capture within tolerance passes.
        let healthy = Self.validateContinuousMicCapture(
            recordedDurationSeconds: 30.0,
            monotonicElapsedSeconds: 30.1,
            events: []
        )
        XCTAssertEqual(healthy, [])
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
            let liveReader = try await BackgroundCAFReader.open(at: cafURL)
            let safeFrames1 = try await liveReader.safeThroughFrame()
            let liveSha1 = try await liveReader.prefixSHA256(committedFrames: safeFrames1)
            await liveReader.close()

            let recordGate = CountGate()
            final class LifecycleRecorder: CaptureRecorder {
                var delegate: (any AVAudioRecorderDelegate)?
                var isMeteringEnabled = false
                var currentTime: TimeInterval = 4.0
                let url: URL
                let onRecord: () -> Void
                var pauses = 0
                init(url: URL, onRecord: @escaping () -> Void) {
                    self.url = url
                    self.onRecord = onRecord
                }
                func record() -> Bool {
                    onRecord()
                    return true
                }
                func pause() { pauses += 1 }
                func stop() {}
                func updateMeters() {}
                func averagePower(forChannel channelNumber: Int) -> Float { -10 }
            }
            let fakeRec = LifecycleRecorder(url: cafURL, onRecord: { recordGate.signal() })
            let fakeSession = CaptureSession(requestPermission: { true }, prepare: {}, activate: {}, deactivate: {})
            let lifecycleAdapter = AVCaptureAdapter(session: fakeSession, makeRecorder: { _ in fakeRec })
            _ = try await lifecycleAdapter.start(url: cafURL)
            try await recordGate.waitFor(count: 1, timeout: .seconds(5))
            let eventGate = CaptureEventGate(stream: lifecycleAdapter.events)
            defer { eventGate.cancel() }
            lifecycleAdapter.pause()
            try lifecycleAdapter.resume()
            try await recordGate.waitFor(count: 2, timeout: .seconds(5))
            NotificationCenter.default.post(
                name: AVAudioSession.interruptionNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]
            )
            try await eventGate.waitFor("interrupted", count: 1, timeout: .seconds(5))
            try lifecycleAdapter.resume()
            try await recordGate.waitFor(count: 3, timeout: .seconds(5))
            NotificationCenter.default.post(
                name: AVAudioSession.routeChangeNotification,
                object: AVAudioSession.sharedInstance(),
                userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue]
            )
            try await eventGate.waitFor("routeLost", count: 1, timeout: .seconds(5))
            _ = try await lifecycleAdapter.stop()

            try Self.writeCAF(to: cafURL, sampleRate: 48_000, pcm: fullPCM, finalized: true)
            let finalReader = try await BackgroundCAFReader.open(at: cafURL)
            let finalSha1 = try await finalReader.prefixSHA256(committedFrames: safeFrames1)
            let finalFrames = try await finalReader.availableFrames()
            await finalReader.close()
            XCTAssertEqual(liveSha1, finalSha1)

            let opusURL = dir.appendingPathComponent("published.opus")
            let opusByteCount = try await Self.encodeOpusOffMainActor(from: cafURL, to: opusURL)
            XCTAssertGreaterThan(opusByteCount, 0)

            let observedEvents = eventGate.observedEvents
            XCTAssertTrue(observedEvents.contains("interrupted"))
            XCTAssertTrue(observedEvents.contains("routeLost"))
            let snap = monitor.finish()
            report["livePrefix1Frames"] = safeFrames1
            report["finalFrames"] = finalFrames
            report["prefix1Matched"] = (liveSha1 == finalSha1)
            report["observedEvents"] = observedEvents
            report["opusBytes"] = opusByteCount
            report["telemetry"] = try Self.asDictionary(snap)
            emitReport(name: "test01-caf-lifecycle", report: report)
            return
        }

        // Start event-gated observer immediately after hardware capture begins (zero fixed sleeps).
        let eventGate = CaptureEventGate(stream: adapter.events)
        defer { eventGate.cancel() }

        // Wait until AVAudioRecorder flushes >= 1 s of PCM16LE frames to capture.caf while live (off MainActor).
        let liveReader = try await BackgroundCAFReader.waitUntilOpen(at: cafURL, timeout: .seconds(15))
        let safeFrames1 = try await liveReader.waitForSafeFrames(
            atLeast: 48_000,
            timeout: .seconds(15),
            description: "initial AVAudioRecorder live CAF flush (>= 1 s)"
        )
        let liveSha1 = try await liveReader.prefixSHA256(committedFrames: safeFrames1)

        // Pause -> Resume lifecycle: verify resume()'s async session activation completes via CAF frame growth.
        adapter.pause()
        let framesAtPause = try await liveReader.safeThroughFrame()
        try adapter.resume()
        let framesAfterResume = try await liveReader.waitForSafeFrames(
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
            try await liveReader.safeThroughFrame()
        )
        try adapter.resume()
        let framesAfterInterruptResume = try await liveReader.waitForSafeFrames(
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
            try await liveReader.safeThroughFrame()
        )
        try adapter.resume()
        let safeFrames2 = try await liveReader.waitForSafeFrames(
            atLeast: framesBeforeRouteResume + 24_000,
            timeout: .seconds(15),
            description: "CAF frame growth after route-loss recovery resume"
        )

        // Capture second live prefix SHA-256 before Stop.
        XCTAssertGreaterThan(safeFrames2, safeFrames1)
        let liveSha2 = try await liveReader.prefixSHA256(committedFrames: safeFrames2)
        await liveReader.close()

        // Finalize via AVAudioRecorder.stop() and compare prefix hashes + Opus publication.
        let finalElapsed = adapter.elapsed
        _ = try await adapter.stop()
        eventGate.cancel()

        let finalReader = try await BackgroundCAFReader.open(at: cafURL)
        let finalFrames = try await finalReader.availableFrames()
        let finalSha1 = try await finalReader.prefixSHA256(committedFrames: safeFrames1)
        let finalSha2 = try await finalReader.prefixSHA256(committedFrames: safeFrames2)
        await finalReader.close()
        XCTAssertEqual(liveSha1, finalSha1, "Live CAF prefix 1 must match finalized CAF bit-for-bit after AVAudioRecorder.stop()")
        XCTAssertEqual(liveSha2, finalSha2, "Live CAF prefix 2 must match finalized CAF bit-for-bit after AVAudioRecorder.stop()")

        let (avFileLength, fileDuration) = try await Self.audioFileLengthAndDurationOffMainActor(url: cafURL)
        XCTAssertGreaterThan(avFileLength, 0)
        XCTAssertLessThan(abs(fileDuration - finalElapsed), 0.5, "Finalized CAF frame count must match active recording duration")

        // Verify Opus publication succeeds on the finalized CAF (encoded off MainActor).
        let opusURL = dir.appendingPathComponent("published.opus")
        let opusByteCount = try await Self.encodeOpusOffMainActor(from: cafURL, to: opusURL)
        XCTAssertGreaterThan(opusByteCount, 0)

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
        report["opusBytes"] = opusByteCount
        report["telemetry"] = try Self.asDictionary(snap)
        emitReport(name: "test01-caf-lifecycle", report: report)
    }

    // MARK: - Opt-in Physical Handset Test 2: Paired Equivalence + 5-min Metrics (Parakeet & Whistle) + Pressure Injection

    @MainActor
    func test02PairedEquivalenceAnd5MinMetrics() async throws {
        guard let config = QualConfig.load() else {
            throw XCTSkip("opt-in physical handset qualification (set CASSINI_HANDSET_QUAL=1 or bundle CassiniHandsetQual.json)")
        }

        let workDir = FileManager.default.temporaryDirectory.appendingPathComponent("qual-5min-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let shortSeconds = config.shortSeconds
        let (speechPCM, speakerSamples16k) = try await Task.detached(priority: .userInitiated) {
            try Self.makeMultiSpeakerSpeech48kPCM16LE(totalSeconds: shortSeconds)
        }.value

        var report: [String: Any] = [
            "test": "test02PairedEquivalenceAnd5MinMetrics",
            "audioSeconds": config.shortSeconds,
            "enrolledVoiceCount": 0,
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
            try XCTSkipUnless(SherpaRuntime.isLinked, "built without SherpaRuntime")
            let modelsRoot = try await Self.ensurePinnedModelsInstalled(in: workDir)
            // Enroll >= 3 distinct saved voices using real CAM++ voiceprint extraction off the main actor.
            let campplusURL = URL(fileURLWithPath: ModelCatalog.voiceprint.path(in: modelsRoot, ModelCatalog.voiceprintModel.name))
            let enrolledVoices = try await Task.detached(priority: .userInitiated) {
                try Self.extractEnrolledVoices(campplusURL: campplusURL, speakerSamples16k: speakerSamples16k)
            }.value
            XCTAssertGreaterThanOrEqual(enrolledVoices.count, 3, "D-1126 requires >= 3 enrolled saved voices")
            report["enrolledVoiceCount"] = enrolledVoices.count

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

            // Anchor speaker diarization & CAM++ saved-voice matching on the identical-CAF control so
            // empty speaker turns or empty voice matches can never silently compare equal across lanes.
            XCTAssertFalse(parakeetCafControl.speakerTurns.isEmpty,
                           "Identical-CAF Parakeet control must produce non-empty Sortformer speaker turns")
            XCTAssertEqual(parakeetCafControl.speakerCount, 3,
                           "Identical-CAF Parakeet control must separate the 3 fixture speakers")
            XCTAssertEqual(Set(parakeetCafControl.speakerTurns.map(\.speaker)).count, 3,
                           "Identical-CAF Parakeet control speaker turns must cover all 3 distinct fixture speakers")
            XCTAssertEqual(parakeetCafControl.matchedVoiceNames, ["Alice", "Carla"],
                           "Identical-CAF Parakeet control must match the expected CAM++ saved voices (Alice, Carla)")
            XCTAssertEqual(parakeetCafControl.matchedVoicesBySpeaker.count, 2,
                           "Identical-CAF Parakeet control must bind both matched voices to distinct speakers")

            // Production end-to-end equivalence (M4A afterStop vs CAF transcribeWhileRecording).
            let parakeetProductionWER = Self.wordErrorRate(reference: parakeetBaseline.words, hypothesis: parakeetHeadStart.words)
            XCTAssertLessThanOrEqual(parakeetProductionWER, 0.02,
                                     "Production Parakeet afterStop (M4A) vs transcribeWhileRecording (CAF) WER must be <= 2%")
            XCTAssertEqual(parakeetHeadStart.speakerCount, parakeetBaseline.speakerCount,
                           "Production Parakeet speaker count must match across M4A vs CAF finalization")
            XCTAssertEqual(parakeetHeadStart.matchedVoiceNames, parakeetBaseline.matchedVoiceNames,
                           "Production Parakeet CAM++ saved-voice matches must match across M4A vs CAF finalization")

            // Strict identical-audio checkpoint equivalence (D109 §1.3: zero drift from CAF prefix resume).
            let parakeetControlProv = try XCTUnwrap(parakeetCafControl.speechProvenance,
                                                    "Identical-CAF Parakeet export must include provenance.speechToText")
            XCTAssertEqual(parakeetControlProv["engine"]?.string, TranscriptProvenance.parakeetEngine,
                           "Parakeet provenance.speechToText must identify Parakeet TDT engine")
            XCTAssertEqual(parakeetHeadStart.speechProvenance, parakeetControlProv,
                           "Identical-CAF Parakeet deterministic provenance.speechToText must match (D109 §1.3)")
            XCTAssertEqual(parakeetHeadStart.opusSha256, parakeetCafControl.opusSha256, "Identical-CAF Parakeet .opus payload must match")
            XCTAssertEqual(parakeetHeadStart.words, parakeetCafControl.words, "Identical-CAF Parakeet words & timings must match")
            XCTAssertEqual(parakeetHeadStart.speakerTurns, parakeetCafControl.speakerTurns, "Identical-CAF Parakeet raw Sortformer turns must match")
            XCTAssertEqual(parakeetHeadStart.matchedVoiceNames, parakeetCafControl.matchedVoiceNames, "Identical-CAF Parakeet CAM++ saved-voice matches must match")
            XCTAssertEqual(parakeetHeadStart.matchedVoicesBySpeaker, parakeetCafControl.matchedVoicesBySpeaker,
                           "Identical-CAF Parakeet CAM++ slot -> voiceName assignments must match")
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
            XCTAssertEqual(parakeetPressure.speechProvenance, parakeetControlProv,
                           "Parakeet pressure-yield deterministic provenance.speechToText must match identical-CAF afterStop")
            XCTAssertEqual(parakeetPressure.words, parakeetCafControl.words, "Parakeet pressure-yield tail recovery must match identical-CAF afterStop")
            XCTAssertEqual(parakeetPressure.speakerTurns, parakeetCafControl.speakerTurns)
            XCTAssertEqual(parakeetPressure.matchedVoiceNames, parakeetCafControl.matchedVoiceNames)
            XCTAssertEqual(parakeetPressure.matchedVoicesBySpeaker, parakeetCafControl.matchedVoicesBySpeaker,
                           "Parakeet pressure-yield CAM++ slot -> voiceName assignments must match identical-CAF afterStop")

            let parakeetEval = Self.evaluateParakeetPaired(
                baseline: parakeetBaseline,
                cafControl: parakeetCafControl,
                headStart: parakeetHeadStart,
                pressure: parakeetPressure
            )
            XCTAssertTrue(parakeetEval.equivalencePassed, "Parakeet paired equivalence checks must all pass")
            XCTAssertTrue(parakeetEval.pressureRecoveryPassed, "Parakeet pressure-recovery checks must all pass")

            report["parakeet"] = [
                "equivalencePassed": parakeetEval.equivalencePassed,
                "productionFinalizationChecked": true,
                "productionAfterStopAudioFilename": parakeetBaseline.audioFilename,
                "productionHeadStartAudioFilename": parakeetHeadStart.audioFilename,
                "productionM4aVsCafWER": parakeetProductionWER,
                "productionM4aVsCafExactWords": (parakeetHeadStart.words == parakeetBaseline.words),
                "productionM4aVsCafDurationDeltaSeconds": abs(parakeetHeadStart.exportedDurationSeconds - parakeetBaseline.exportedDurationSeconds),
                "pressureRecoveryPassed": parakeetEval.pressureRecoveryPassed,
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
            let whistleControlProv = try XCTUnwrap(whistleCafControl.speechProvenance,
                                                   "Identical-CAF Whistle export must include provenance.speechToText")
            XCTAssertEqual(whistleControlProv["engine"]?.string, "Whistle",
                           "Whistle provenance.speechToText must identify Whistle engine")
            XCTAssertEqual(whistleHeadStart.speechProvenance, whistleControlProv,
                           "Identical-CAF Whistle deterministic provenance.speechToText must match (D109 §1.3)")
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
            XCTAssertEqual(whistlePressure.speechProvenance, whistleControlProv,
                           "Whistle pressure-yield deterministic provenance.speechToText must match identical-CAF afterStop")
            XCTAssertEqual(whistlePressure.words, whistleCafControl.words, "Whistle pressure-yield tail recovery must match identical-CAF afterStop")

            let whistleEval = Self.evaluateWhistlePaired(
                baseline: whistleBaseline,
                cafControl: whistleCafControl,
                headStart: whistleHeadStart,
                pressure: whistlePressure
            )
            XCTAssertTrue(whistleEval.equivalencePassed, "Whistle paired equivalence checks must all pass")
            XCTAssertTrue(whistleEval.pressureRecoveryPassed, "Whistle pressure-recovery checks must all pass")

            report["whistle"] = [
                "equivalencePassed": whistleEval.equivalencePassed,
                "productionFinalizationChecked": true,
                "productionAfterStopAudioFilename": whistleBaseline.audioFilename,
                "productionHeadStartAudioFilename": whistleHeadStart.audioFilename,
                "productionM4aVsCafWER": whistleProductionWER,
                "productionM4aVsCafExactWords": (whistleHeadStart.words == whistleBaseline.words),
                "productionM4aVsCafDurationDeltaSeconds": abs(whistleHeadStart.exportedDurationSeconds - whistleBaseline.exportedDurationSeconds),
                "pressureRecoveryPassed": whistleEval.pressureRecoveryPassed,
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
        // Keep only a single ~35 s multi-speaker cycle (~3.3 MiB) in memory (built off MainActor) and stream slices
        // to disk so the 30-min harness does not retain ~165 MiB of synthetic PCM in RAM during RSS telemetry.
        let cyclePCM = try await Task.detached(priority: .userInitiated) {
            try Self.makeMultiSpeakerSpeechCycle48kPCM16LE()
        }.value
        XCTAssertFalse(cyclePCM.isEmpty)

        let notesRoot = workDir.appendingPathComponent("notes", isDirectory: true)
        let notes = try NoteStore(root: notesRoot)
        var note = Note(title: "Long \(engine.rawValue)", audioFilename: "capture.caf")
        note.duration = Double(totalSeconds)
        try await notes.save(note)
        let speechCAF = notes.audioURL(for: note)
        // Start with an empty unfinalized CAF header and append 2 s every 2 s on a background actor
        // so disk writes and flushes never block `@MainActor`.
        let cafWriter = QualCAFWriter(url: speechCAF)
        _ = try await cafWriter.create(sampleRate: 48_000, initialPCM: Data(), finalized: false)

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
        var micMonotonicStart: UInt64 = 0
        var micError: String?
        let micPermission = AVAudioApplication.shared.recordPermission
        if micPermission == .granted {
            _ = try await micAdapter.start(url: micCAF)
            micMonotonicStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
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
        // streaming slices from the bounded single-cycle buffer via the background CAF writer actor.
        let chunkSeconds = 2
        let bytesPerSecond = 48_000 * 2
        var writtenSeconds = 0
        var cycleOffset = 0
        while writtenSeconds < totalSeconds {
            let nextEnd = min(totalSeconds, writtenSeconds + chunkSeconds)
            let (nextOffset, _) = try await cafWriter.appendCycleSlice(
                from: cyclePCM,
                offset: cycleOffset,
                byteCount: (nextEnd - writtenSeconds) * bytesPerSecond
            )
            cycleOffset = nextOffset
            writtenSeconds = nextEnd
            if writtenSeconds < totalSeconds {
                try await Task.sleep(for: .seconds(chunkSeconds))
            }
        }
        // Measure Stop-to-published-transcript latency from capture end (covering CAF finalization,
        // microphone stop, precomputer stop, and post-Stop TranscriptionJob completion).
        let stopStart = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
        // Finalize the CAF header just as AVAudioRecorder.stop() does, using the writer's streamed byte counter.
        try await cafWriter.finalizeHeader()

        // Stop hardware mic and precomputer.
        let micElapsed = micStarted ? micAdapter.elapsed : 0
        let micMonotonicElapsed: Double
        if micStarted {
            _ = try await micAdapter.stop()
            micMonotonicElapsed = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - micMonotonicStart) / 1_000_000_000.0
        } else {
            micMonotonicElapsed = 0
        }
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
        let capturedRequest = Mutex<TranscriptionRequest?>(nil)
        let observingTranscriber = CountingTranscriber(
            inner: transcriber,
            onRequest: { req in capturedRequest.withLock { $0 = req } }
        )
        let longHost = LongRunJobHost(identifySpeakers: engine == .parakeet)
        let job = TranscriptionJob(notes: notes, transcriber: observingTranscriber, analyzer: analyzer,
                                   checkpoints: checkpoints, provenance: provenance,
                                   host: longHost,
                                   clock: SystemClock(), budget: budget)
        let outcome = await job.run(Job(noteID: note.id, seq: 1, kind: .transcribe, state: .running, enqueuedAt: Date()),
                                    stop: StopSignal()) { _ in }
        let stopToPublished = Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW) - stopStart) / 1_000_000_000.0
        let postStopSnap = postStopMonitor.finish()
        XCTAssertEqual(outcome, JobOutcome.done)

        let finalRequest = capturedRequest.withLock { $0 }
        let resumeFailures = Self.validateLongRunCheckpointResume(engine: engine, request: finalRequest)
        XCTAssertEqual(resumeFailures, [], "30-min post-Stop job must resume from recording-time checkpoint rather than restarting from 0")

        // Inspect hardware mic CAF for dropped frames / continuity (outside the Stop-to-published timer).
        var micFrames: Int64 = 0
        var micDuration: Double = 0
        var droppedFrameDriftSeconds: Double = 0
        if micStarted {
            let (frames, duration) = try await Self.audioFileLengthAndDurationOffMainActor(url: micCAF)
            micFrames = frames
            micDuration = duration
            droppedFrameDriftSeconds = abs(micDuration - micMonotonicElapsed)
            let continuityFailures = Self.validateContinuousMicCapture(
                recordedDurationSeconds: micDuration,
                monotonicElapsedSeconds: micMonotonicElapsed,
                events: micEvents.withLock { $0 }
            )
            XCTAssertEqual(continuityFailures, [], "30-min continuous mic capture must have zero interruptions/route-loss/errors and match monotonic elapsed duration")
        }

        let stored = await notes.note(note.id)
        let saved = try XCTUnwrap(stored)
        let wordCount = Self.extractComparableWords(from: saved.transcript, includeSpeaker: false).count
        XCTAssertGreaterThan(wordCount, 0)
        if engine == .parakeet {
            let speakerFailures = Self.validateLongRunParakeetSpeakers(
                speakerAnalysisFailure: saved.speakerAnalysisFailure,
                analysis: longHost.recordedAnalysis,
                totalDurationSeconds: Double(totalSeconds)
            )
            XCTAssertEqual(speakerFailures, [], "30-min Parakeet Sortformer must remain healthy through the end of the recording")
        }

        let resumedFromMs: Int64 = switch engine {
        case .parakeet: finalRequest?.resume?.recognition.doneMs ?? 0
        case .whistle: Int64(finalRequest?.whistleResume?.processedSamples ?? 0) * 1000 / 16_000
        }

        let report: [String: Any] = [
            "test": "runThirtyMinuteContinuousCapture",
            "engine": engine.rawValue,
            "audioSeconds": totalSeconds,
            "precomputeCheckpointsSaved": precomputeCheckpointsSaved,
            "postStopResumedFromMs": resumedFromMs,
            "stopToPublishedSeconds": stopToPublished,
            "wordCount": wordCount,
            "micStarted": micStarted,
            "micError": micError ?? "none",
            "micElapsedSeconds": micElapsed,
            "micMonotonicElapsedSeconds": micMonotonicElapsed,
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
        let speechProvenance: JSONObject?
        let exportedDurationSeconds: Double
        let opusSha256: String
        let words: [ComparableWord]
        let speakerTurns: [ComparableTurn]
        let speakerCount: Int
        let matchedVoiceNames: [String]
        let matchedVoicesBySpeaker: [String: String]
        let precomputeCheckpointsSaved: Int
        let checkpointsAtPressureInjection: Int?
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
        let decodedCAF = root.appendingPathComponent("decoded-export.caf")
        let inspected = try await Self.inspectExportedOpus(opusURL: exportedURL, scratchCAFURL: decodedCAF)
        return ProductionExportContractResult(
            audioFilename: saved.audioFilename,
            exportVerified: inspected.exportVerified,
            exportedDurationSeconds: inspected.durationSeconds
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

        // Append any remaining tail audio before starting the Stop-to-published timer so `fileCapture.stop()`
        // only finalizes the CAF header in place (matching real AVAudioRecorder.stop() without rewriting 29 MB).
        try await fileCapture.appendRemainingAudio()

        // Production Stop -> RecordingController.finishAudio -> TranscriptionJob (timed);
        // PortableExportService export is verified separately afterward.
        let postStopWindows = Mutex(0)
        let host = MatchingJobHost(notes: notes, voices: enrolledVoices)
        let transcriber = ParakeetTranscriber(models: parakeetModels, runtime: SherpaRuntime.speech)
        let countingTranscriber = CountingTranscriber(
            inner: transcriber,
            onWindow: { postStopWindows.withLock { $0 += 1 } }
        )
        let job = TranscriptionJob(notes: notes, transcriber: countingTranscriber, analyzer: analyzer,
                                   checkpoints: checkpoints, provenance: provenance, host: host,
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

        // Verify exported CassiniDocument, extract deterministic provenance, and decode/hash PCM off MainActor.
        let decodedOpusCAF = root.appendingPathComponent("decoded-opus.caf")
        let inspected = try await Self.inspectExportedOpus(
            opusURL: opusURL,
            scratchCAFURL: decodedOpusCAF
        )
        let words = Self.extractComparableWords(from: saved.transcript, includeSpeaker: true)
        let turns = Self.canonicalizeSpeakerTurns(host.recordedTurns)
        return PairedLaneResult(
            audioFilename: saved.audioFilename,
            exportVerified: inspected.exportVerified,
            speechProvenance: inspected.speechProvenance,
            exportedDurationSeconds: inspected.durationSeconds,
            opusSha256: inspected.pcmSha256,
            words: words,
            speakerTurns: turns,
            speakerCount: saved.speakers?.count ?? 0,
            matchedVoiceNames: host.matchedNames.sorted(),
            matchedVoicesBySpeaker: Self.canonicalizeVoiceMap(host.matchedVoicesBySpeaker),
            precomputeCheckpointsSaved: precomputeSaved,
            checkpointsAtPressureInjection: countAtInjection.withLock { $0 },
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

        // Append any remaining tail audio before starting the Stop-to-published timer so `fileCapture.stop()`
        // only finalizes the CAF header in place (matching real AVAudioRecorder.stop() without rewriting 29 MB).
        try await fileCapture.appendRemainingAudio()

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

        // Verify exported CassiniDocument, extract deterministic provenance, and decode/hash PCM off MainActor.
        let decodedOpusCAF = root.appendingPathComponent("decoded-opus.caf")
        let inspected = try await Self.inspectExportedOpus(
            opusURL: opusURL,
            scratchCAFURL: decodedOpusCAF
        )
        let words = Self.extractComparableWords(from: saved.transcript, includeSpeaker: false)
        return PairedLaneResult(
            audioFilename: saved.audioFilename,
            exportVerified: inspected.exportVerified,
            speechProvenance: inspected.speechProvenance,
            exportedDurationSeconds: inspected.durationSeconds,
            opusSha256: inspected.pcmSha256,
            words: words,
            speakerTurns: [],
            speakerCount: 0,
            matchedVoiceNames: [],
            matchedVoicesBySpeaker: [:],
            precomputeCheckpointsSaved: precomputeSaved,
            checkpointsAtPressureInjection: countAtInjection.withLock { $0 },
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
            let timeoutTaskHolder = Mutex<Task<Void, Never>?>(nil)
            defer { timeoutTaskHolder.withLock { $0 }?.cancel() }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let alreadySatisfied = state.withLock { s -> Bool in
                    if s.observed.filter({ $0 == name }).count >= count { return true }
                    s.waiters.append((waiterID, name, count, continuation))
                    return false
                }
                if alreadySatisfied {
                    continuation.resume()
                    return
                }
                // Arm timeout ONLY after the waiter continuation is registered so an immediate expiry cannot race ahead.
                let task = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, let self else { return }
                    let expired = self.state.withLock { s -> CheckedContinuation<Void, any Error>? in
                        guard let idx = s.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                        return s.waiters.remove(at: idx).continuation
                    }
                    expired?.resume(throwing: TimeoutError(message: "Timed out after \(timeout) waiting for capture event '\(name)' (count >= \(count))"))
                }
                timeoutTaskHolder.withLock { $0 = task }
            }
        }
    }

    /// Serial background actor wrapping `LiveCAFReader` so file opens, `safeThroughFrame()` / `availableFrames()`
    /// seeks, and prefix SHA-256 reads never run synchronously on `@MainActor`.
    private actor BackgroundCAFReader {
        private var reader: LiveCAFReader?

        static func waitUntilOpen(at url: URL, timeout: Duration) async throws -> BackgroundCAFReader {
            let instance = BackgroundCAFReader()
            try await instance.openWhenReady(at: url, timeout: timeout)
            return instance
        }

        static func open(at url: URL) async throws -> BackgroundCAFReader {
            let instance = BackgroundCAFReader()
            try await instance.openNow(at: url)
            return instance
        }

        private func openNow(at url: URL) throws {
            reader = try LiveCAFReader(url: url)
        }

        private func openWhenReady(at url: URL, timeout: Duration) async throws {
            let deadline = ContinuousClock.now + timeout
            while true {
                if let opened = try? LiveCAFReader(url: url) {
                    reader = opened
                    return
                }
                if ContinuousClock.now >= deadline {
                    throw TimeoutError(message: "Timed out after \(timeout) waiting for LiveCAFReader to open \(url.lastPathComponent)")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        func safeThroughFrame(safetyMarginFrames: UInt64 = LiveCAFReader.defaultSafetyMarginFrames) throws -> UInt64 {
            guard let reader else { throw TimeoutError(message: "BackgroundCAFReader is closed") }
            return try reader.safeThroughFrame(safetyMarginFrames: safetyMarginFrames)
        }

        func waitForSafeFrames(atLeast targetFrames: UInt64, timeout: Duration, description: String) async throws -> UInt64 {
            let deadline = ContinuousClock.now + timeout
            while true {
                let safe = (try? safeThroughFrame()) ?? 0
                if safe >= targetFrames { return safe }
                if ContinuousClock.now >= deadline {
                    throw TimeoutError(message: "Timed out after \(timeout) waiting for \(description): reached \(safe) / \(targetFrames) frames")
                }
                try await Task.sleep(for: .milliseconds(25))
            }
        }

        func availableFrames() throws -> UInt64 {
            guard let reader else { throw TimeoutError(message: "BackgroundCAFReader is closed") }
            return try reader.availableFrames()
        }

        func prefixSHA256(committedFrames: UInt64) throws -> String {
            guard let reader else { throw TimeoutError(message: "BackgroundCAFReader is closed") }
            return try reader.prefixSHA256(committedFrames: committedFrames)
        }

        func close() {
            reader?.close()
            reader = nil
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

    private static func validateLongRunCheckpointResume(
        engine: LongEngine,
        request: TranscriptionRequest?
    ) -> [String] {
        guard let request else {
            return ["Post-Stop TranscriptionJob never invoked transcriber for \(engine.rawValue)"]
        }
        switch engine {
        case .parakeet:
            guard let resume = request.resume, resume.recognition.doneMs > 0 else {
                return ["30-min Parakeet post-Stop job discarded recording-time checkpoint (resume.doneMs == \(request.resume?.recognition.doneMs ?? 0))"]
            }
            return []
        case .whistle:
            guard let wResume = request.whistleResume, wResume.processedSamples > 0 else {
                return ["30-min Whistle post-Stop job discarded recording-time checkpoint (whistleResume.processedSamples == \(request.whistleResume?.processedSamples ?? 0))"]
            }
            return []
        }
    }

    private static func validateLongRunParakeetSpeakers(
        speakerAnalysisFailure: JobFailure?,
        analysis: SpeakerAnalysis?,
        totalDurationSeconds: Double
    ) -> [String] {
        var failures: [String] = []
        if let failure = speakerAnalysisFailure {
            failures.append("30-min Parakeet speakerAnalysisFailure must be nil (got \(failure))")
        }
        guard let analysis, !analysis.turns.isEmpty else {
            failures.append("30-min Parakeet Sortformer produced no speaker turns")
            return failures
        }
        let lateThreshold = totalDurationSeconds * 0.8
        let lateTurns = analysis.turns.filter { $0.end >= lateThreshold }
        let distinctLateSpeakers = Set(lateTurns.map { canonicalSpeakerSlot($0.speakerID) })
        if distinctLateSpeakers.count < 2 {
            let maxEnd = analysis.turns.map(\.end).max() ?? 0
            failures.append(
                "30-min Parakeet Sortformer must produce >= 2 distinct speakers in the final 20% (>= \(Int(lateThreshold))s); got \(distinctLateSpeakers.count) (maxTurnEnd=\(String(format: "%.1f", maxEnd))s)"
            )
        }
        return failures
    }

    private static func validateContinuousMicCapture(
        recordedDurationSeconds: Double,
        monotonicElapsedSeconds: Double,
        events: [String],
        maxDriftSeconds: Double = 0.5
    ) -> [String] {
        var failures: [String] = []
        if !events.isEmpty {
            failures.append("Unexpected capture events during continuous recording: \(events)")
        }
        let drift = abs(recordedDurationSeconds - monotonicElapsedSeconds)
        if drift >= maxDriftSeconds {
            failures.append(
                String(
                    format: "Mic CAF duration (%.2fs) drifted from monotonic capture interval (%.2fs) by %.2fs >= %.2fs",
                    recordedDurationSeconds, monotonicElapsedSeconds, drift, maxDriftSeconds
                )
            )
        }
        return failures
    }

    /// Extracts timed words strictly from `seg.words` (never falling back to `seg.draftWords` when word timings are missing).
    private static func extractComparableWords(from segments: [TranscriptSegment], includeSpeaker: Bool) -> [ComparableWord] {
        segments.flatMap { seg in
            seg.words.map { word in
                ComparableWord(
                    text: word.text,
                    startMs: Int64((word.start * 1000).rounded()),
                    endMs: Int64((word.end * 1000).rounded()),
                    speaker: includeSpeaker ? seg.speaker : nil
                )
            }
        }
    }

    private struct PairedEvaluation: Equatable {
        let equivalencePassed: Bool
        let pressureRecoveryPassed: Bool
    }

    private static func evaluateParakeetPaired(
        baseline: PairedLaneResult,
        cafControl: PairedLaneResult,
        headStart: PairedLaneResult,
        pressure: PairedLaneResult
    ) -> PairedEvaluation {
        let productionWER = wordErrorRate(reference: baseline.words, hypothesis: headStart.words)
        let controlProv = cafControl.speechProvenance
        let productionOK =
            baseline.audioFilename == RecordingController.compressedFilename &&
            headStart.audioFilename == RecordingController.captureFilename &&
            baseline.exportVerified &&
            headStart.exportVerified &&
            abs(headStart.exportedDurationSeconds - baseline.exportedDurationSeconds) < 0.15 &&
            productionWER <= 0.02 &&
            headStart.speakerCount == baseline.speakerCount &&
            headStart.matchedVoiceNames == baseline.matchedVoiceNames
        let controlAnchorOK =
            !baseline.words.isEmpty &&
            !cafControl.words.isEmpty &&
            !cafControl.speakerTurns.isEmpty &&
            cafControl.speakerCount == 3 &&
            Set(cafControl.speakerTurns.map(\.speaker)).count == 3 &&
            cafControl.matchedVoiceNames == ["Alice", "Carla"] &&
            cafControl.matchedVoicesBySpeaker.count == 2 &&
            controlProv?["engine"]?.string == TranscriptProvenance.parakeetEngine
        let headStartIdenticalOK =
            controlProv != nil &&
            headStart.speechProvenance == controlProv &&
            headStart.opusSha256 == cafControl.opusSha256 &&
            headStart.words == cafControl.words &&
            headStart.speakerTurns == cafControl.speakerTurns &&
            headStart.matchedVoiceNames == cafControl.matchedVoiceNames &&
            headStart.matchedVoicesBySpeaker == cafControl.matchedVoicesBySpeaker &&
            headStart.precomputeCheckpointsSaved > 0 &&
            headStart.postStopWindowsDecoded < baseline.postStopWindowsDecoded
        let pressureYieldedOK: Bool = {
            guard let injectedAt = pressure.checkpointsAtPressureInjection, injectedAt >= 1 else { return false }
            return pressure.precomputeCheckpointsSaved <= injectedAt + 1
        }()
        let pressureOK =
            controlAnchorOK &&
            controlProv != nil &&
            pressureYieldedOK &&
            pressure.speechProvenance == controlProv &&
            pressure.words == cafControl.words &&
            pressure.speakerTurns == cafControl.speakerTurns &&
            pressure.matchedVoiceNames == cafControl.matchedVoiceNames &&
            pressure.matchedVoicesBySpeaker == cafControl.matchedVoicesBySpeaker
        return PairedEvaluation(
            equivalencePassed: productionOK && controlAnchorOK && headStartIdenticalOK,
            pressureRecoveryPassed: pressureOK
        )
    }

    private static func evaluateWhistlePaired(
        baseline: PairedLaneResult,
        cafControl: PairedLaneResult,
        headStart: PairedLaneResult,
        pressure: PairedLaneResult
    ) -> PairedEvaluation {
        let productionWER = wordErrorRate(reference: baseline.words, hypothesis: headStart.words)
        let controlProv = cafControl.speechProvenance
        let productionOK =
            baseline.audioFilename == RecordingController.compressedFilename &&
            headStart.audioFilename == RecordingController.captureFilename &&
            baseline.exportVerified &&
            headStart.exportVerified &&
            abs(headStart.exportedDurationSeconds - baseline.exportedDurationSeconds) < 0.15 &&
            productionWER <= 0.02
        let nonEmptyWords = !baseline.words.isEmpty && !cafControl.words.isEmpty
        let headStartIdenticalOK =
            nonEmptyWords &&
            controlProv != nil &&
            controlProv?["engine"]?.string == "Whistle" &&
            headStart.speechProvenance == controlProv &&
            headStart.opusSha256 == cafControl.opusSha256 &&
            headStart.words == cafControl.words &&
            headStart.precomputeCheckpointsSaved > 0 &&
            headStart.postStopSegmentsDecoded < baseline.postStopSegmentsDecoded
        let pressureYieldedOK: Bool = {
            guard let injectedAt = pressure.checkpointsAtPressureInjection, injectedAt >= 1 else { return false }
            return pressure.precomputeCheckpointsSaved <= injectedAt + 1
        }()
        let pressureOK =
            nonEmptyWords &&
            controlProv != nil &&
            controlProv?["engine"]?.string == "Whistle" &&
            pressureYieldedOK &&
            pressure.speechProvenance == controlProv &&
            pressure.words == cafControl.words
        return PairedEvaluation(
            equivalencePassed: productionOK && headStartIdenticalOK,
            pressureRecoveryPassed: pressureOK
        )
    }

    private struct ExportedOpusInspection: Sendable {
        let exportVerified: Bool
        let speechProvenance: JSONObject?
        let durationSeconds: Double
        let pcmSha256: String
    }

    /// Reads and verifies an exported `.opus` `CassiniDocument`, decodes it to CAF, and computes its
    /// decoded duration and streaming SHA-256 completely off `@MainActor`.
    private static func inspectExportedOpus(opusURL: URL, scratchCAFURL: URL) async throws -> ExportedOpusInspection {
        try await Task.detached(priority: .userInitiated) {
            let doc = CassiniDocument.read(opusURL)
            let verified = (doc.state == DocumentState.ok)
            let provenance = Self.deterministicSpeechProvenance(from: doc)
            try OpusAudio.decode(opusURL, to: scratchCAFURL)
            defer { try? FileManager.default.removeItem(at: scratchCAFURL) }
            let decodedFile = try AVAudioFile(forReading: scratchCAFURL)
            let duration = Double(decodedFile.length) / decodedFile.fileFormat.sampleRate
            let handle = try FileHandle(forReadingFrom: scratchCAFURL)
            defer { try? handle.close() }
            var hasher = SHA256()
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
            let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            return ExportedOpusInspection(
                exportVerified: verified,
                speechProvenance: provenance,
                durationSeconds: duration,
                pcmSha256: digest
            )
        }.value
    }

    /// Encodes a CAF to `.opus` off `@MainActor` and returns the encoded file size in bytes.
    private static func encodeOpusOffMainActor(from cafURL: URL, to opusURL: URL) async throws -> Int {
        try await Task.detached(priority: .userInitiated) {
            try OpusAudio.encode(cafURL, to: opusURL)
            return try opusURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        }.value
    }

    /// Reads an audio file's frame length and duration off `@MainActor`.
    private static func audioFileLengthAndDurationOffMainActor(url: URL) async throws -> (frames: Int64, duration: Double) {
        try await Task.detached(priority: .userInitiated) {
            let avFile = try AVAudioFile(forReading: url)
            return (avFile.length, Double(avFile.length) / avFile.fileFormat.sampleRate)
        }.value
    }

    /// Event-driven counter gate with bounded timeout (zero fixed sleeps when signaled immediately).
    private final class CountGate: @unchecked Sendable {
        private struct State {
            var count = 0
            var waiters: [(id: UUID, target: Int, continuation: CheckedContinuation<Void, any Error>)] = []
        }

        private let state = Mutex(State())

        func signal() {
            let ready = state.withLock { s -> [CheckedContinuation<Void, any Error>] in
                s.count += 1
                var matched: [CheckedContinuation<Void, any Error>] = []
                s.waiters.removeAll { waiter in
                    if s.count >= waiter.target {
                        matched.append(waiter.continuation)
                        return true
                    }
                    return false
                }
                return matched
            }
            for cont in ready { cont.resume() }
        }

        func waitFor(count target: Int, timeout: Duration) async throws {
            let waiterID = UUID()
            let timeoutTaskHolder = Mutex<Task<Void, Never>?>(nil)
            defer { timeoutTaskHolder.withLock { $0 }?.cancel() }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                let satisfied = state.withLock { s -> Bool in
                    if s.count >= target { return true }
                    s.waiters.append((waiterID, target, cont))
                    return false
                }
                if satisfied {
                    cont.resume()
                    return
                }
                // Arm timeout ONLY after the waiter continuation is registered so an immediate expiry cannot race ahead.
                let task = Task { [weak self] in
                    try? await Task.sleep(for: timeout)
                    guard !Task.isCancelled, let self else { return }
                    let expired = self.state.withLock { s -> CheckedContinuation<Void, any Error>? in
                        guard let idx = s.waiters.firstIndex(where: { $0.id == waiterID }) else { return nil }
                        return s.waiters.remove(at: idx).continuation
                    }
                    expired?.resume(throwing: TimeoutError(message: "Timed out after \(timeout) waiting for recorder.record() count >= \(target)"))
                }
                timeoutTaskHolder.withLock { $0 = task }
            }
        }
    }

    /// Strips a leading `WindowSpeakers.freshPrefix()` (`<UUID>_`) while preserving the Sortformer slot suffix.
    private static func canonicalSpeakerSlot(_ speakerID: String) -> String {
        if let underscore = speakerID.firstIndex(of: "_") {
            let prefix = String(speakerID[..<underscore])
            if UUID(uuidString: prefix) != nil {
                return String(speakerID[speakerID.index(after: underscore)...])
            }
        }
        return speakerID
    }

    private static func canonicalizeSpeakerTurns(_ turns: [SpeakerTurn]) -> [ComparableTurn] {
        turns.map { turn in
            ComparableTurn(
                speaker: canonicalSpeakerSlot(turn.speakerID),
                startMs: Int64((turn.start * 1000).rounded()),
                endMs: Int64((turn.end * 1000).rounded())
            )
        }
    }

    private static func canonicalizeVoiceMap(_ map: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for (speakerID, voiceName) in map {
            out[canonicalSpeakerSlot(speakerID)] = voiceName
        }
        return out
    }

    /// Extracts deterministic `provenance.speechToText` fields from an exported `CassiniDocument`,
    /// excluding run-specific timing and resume-offset measurements (`x-inferenceMs`, `x-resumedFromMs`,
    /// and `x-speakerDiarization.elapsedMs`).
    private static func deterministicSpeechProvenance(from doc: CassiniDocument) -> JSONObject? {
        guard let speechToText = doc.manifest?["provenance"]?.object?["speechToText"]?.object,
              let firstEntry = speechToText.pairs.first?.value.object else {
            return nil
        }
        var normalized = firstEntry
        normalized["x-inferenceMs"] = nil
        normalized["x-resumedFromMs"] = nil
        if var diar = normalized["x-speakerDiarization"]?.object {
            diar["elapsedMs"] = nil
            normalized["x-speakerDiarization"] = .object(diar)
        }
        return normalized
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

    /// Serial background actor for CAF creation, chunked appends, disk flushes, and in-place header finalization,
    /// keeping all file I/O off `@MainActor`.
    private actor QualCAFWriter {
        private let url: URL
        private var handle: FileHandle?
        private var bytesWritten: UInt64 = 0

        init(url: URL) {
            self.url = url
        }

        func create(sampleRate: Double, initialPCM: Data, finalized: Bool) throws -> UInt64 {
            try HandsetQualificationTests.writeCAF(to: url, sampleRate: sampleRate, pcm: initialPCM, finalized: finalized)
            bytesWritten = UInt64(initialPCM.count)
            return bytesWritten
        }

        func append(_ data: Data) throws -> UInt64 {
            guard !data.isEmpty else { return bytesWritten }
            let fh: FileHandle
            if let existing = handle {
                fh = existing
            } else {
                fh = try FileHandle(forWritingTo: url)
                try fh.seekToEnd()
                handle = fh
            }
            try fh.write(contentsOf: data)
            try fh.synchronize()
            bytesWritten += UInt64(data.count)
            return bytesWritten
        }

        func appendCycleSlice(from cyclePCM: Data, offset: Int, byteCount: Int) throws -> (newOffset: Int, totalBytes: UInt64) {
            let fh: FileHandle
            if let existing = handle {
                fh = existing
            } else {
                fh = try FileHandle(forWritingTo: url)
                try fh.seekToEnd()
                handle = fh
            }
            var remaining = byteCount
            var cur = offset
            while remaining > 0 {
                let take = min(remaining, cyclePCM.count - cur)
                try fh.write(contentsOf: cyclePCM[cur..<(cur + take)])
                bytesWritten += UInt64(take)
                remaining -= take
                cur = (cur + take) % cyclePCM.count
            }
            try fh.synchronize()
            return (cur, bytesWritten)
        }

        func finalizeHeader() throws {
            if let existing = handle {
                try existing.close()
                handle = nil
            }
            try HandsetQualificationTests.finalizeCAFHeader(at: url, pcmBytes: bytesWritten)
        }
    }

    @MainActor
    private final class QualFileCapture: AudioCapture {
        let events: AsyncStream<CaptureEvent>
        private let continuation: AsyncStream<CaptureEvent>.Continuation
        var elapsed: TimeInterval = 0
        private(set) var recordedAt: Date?
        private var writer: QualCAFWriter?
        private var bytesWritten: Int = 0
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
            writer == nil ? 0 : Int64(bytesWritten) + 64
        }

        func start(url: URL) async throws -> CaptureFormat {
            let w = QualCAFWriter(url: url)
            self.writer = w
            self.recordedAt = Date()
            let initial = prefixPCM ?? fullPCM
            let written = try await w.create(sampleRate: 48_000, initialPCM: initial, finalized: false)
            self.bytesWritten = Int(written)
            self.elapsed = Double(written / 2) / 48_000.0
            return .pcm48kMono
        }

        /// Appends any remaining fixture PCM beyond the precompute prefix on the background actor before Stop is timed.
        func appendRemainingAudio() async throws {
            guard let w = writer, bytesWritten < fullPCM.count else { return }
            let tail = Data(fullPCM[bytesWritten..<fullPCM.count])
            let written = try await w.append(tail)
            self.bytesWritten = Int(written)
            self.elapsed = fullDuration
        }

        func pause() {}
        func resume() throws {}

        func stop() async throws -> CaptureResult {
            try await appendRemainingAudio()
            try await writer?.finalizeHeader()
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

    private final class LongRunJobHost: TranscriptionJobHost, @unchecked Sendable {
        let identifySpeakers: Bool
        private let analysisStorage = Mutex<SpeakerAnalysis?>(nil)
        var recordedAnalysis: SpeakerAnalysis? { analysisStorage.withLock { $0 } }

        init(identifySpeakers: Bool) { self.identifySpeakers = identifySpeakers }

        func jobSettings() async -> JobSettings {
            JobSettings(allowSpeechDownload: false, identifySpeakers: identifySpeakers, allowSpeakerDownload: false,
                        voicesGeneration: 0, automaticallyNameVoices: false)
        }
        func liveVoices(generation: Int) async -> @Sendable () -> [SavedVoice] { { [] } }
        func applySpeakers(_ analysis: SpeakerAnalysis, to noteID: UUID, generation: Int) async throws {
            analysisStorage.withLock { $0 = analysis }
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
        private let matchedBySpeakerStorage = Mutex<[String: String]>([:])
        private let turnsStorage = Mutex<[SpeakerTurn]>([])
        var matchedNames: [String] { matched.withLock { $0 } }
        var matchedVoicesBySpeaker: [String: String] { matchedBySpeakerStorage.withLock { $0 } }
        var recordedTurns: [SpeakerTurn] { turnsStorage.withLock { $0 } }

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
            turnsStorage.withLock { $0 = analysis.turns }
            guard var note = await notes.note(noteID) else { return }
            let matching = AnalysisMatches.of(note, turns: analysis.turns, prints: analysis.prints,
                                              savedVoices: voices, earlierPrints: [], trashed: [], excluded: [:])
            var bySpeaker: [String: String] = [:]
            for (speakerID, match) in matching.matches {
                if let name = voices.first(where: { $0.id == match.voiceID })?.name {
                    bySpeaker[speakerID] = name
                }
            }
            matchedBySpeakerStorage.withLock { $0 = bySpeaker }
            matched.withLock { $0 = Array(bySpeaker.values) }
            matching.apply(to: &note, turns: analysis.turns, autoName: true, stamp: VersionStamp(date: Date()),
                           attributed: analysis.transcript, excluded: [:], labels: [:], colourIndices: [:], explicitNames: [])
            try await notes.save(note)
        }
    }

    private struct CountingTranscriber: Transcribing {
        let inner: any Transcribing
        let onRequest: @Sendable (TranscriptionRequest) -> Void
        let onWindow: @Sendable () -> Void
        let onSegment: @Sendable (Int) -> Void

        init(inner: any Transcribing,
             onRequest: @escaping @Sendable (TranscriptionRequest) -> Void = { _ in },
             onWindow: @escaping @Sendable () -> Void = {},
             onSegment: @escaping @Sendable (Int) -> Void = { _ in }) {
            self.inner = inner
            self.onRequest = onRequest
            self.onWindow = onWindow
            self.onSegment = onSegment
        }

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
            onRequest(request)
            return try await inner.transcribe(request) { event in
                switch event {
                case .window:
                    onWindow()
                case .whistleBatch(let batch) where !batch.segments.isEmpty:
                    onSegment(batch.segments.count)
                default:
                    break
                }
                events(event)
            }
        }
    }
}
