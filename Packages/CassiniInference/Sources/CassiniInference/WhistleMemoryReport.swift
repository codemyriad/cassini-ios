import Foundation
import Darwin
import Synchronization
#if os(iOS)
import os
#endif

/// Diagnostic numbers only: no audio, words, note identifiers or paths. Peaks are the kernel's process high-water
/// marks, not just timer observations; the timer additionally records low headroom and thermal/warning events.
public struct WhistleMemoryReport: Codable, Sendable {
    public var scope: String
    public var jobKind: String?
    public var physicalMemoryBytes: UInt64
    public var operatingSystem: String
    public var baselineFootprintBytes: UInt64
    public var peakFootprintBytes: UInt64
    public var peakResidentBytes: UInt64
    public var minimumAvailableBytes: UInt64?
    public var memoryWarnings: Int
    public var maximumThermalState: Int
    public var elapsedMilliseconds: Int64
    public var succeeded: Bool
    public var nativeModelReleased: Bool
}

/// All mutable measurement state is under one mutex. Timer and notification callbacks never touch UI/app state.
public final class WhistleMemoryMonitor: @unchecked Sendable {
    private struct State {
        var peakFootprint: UInt64 = 0, peakResident: UInt64 = 0
        var baseline: UInt64 = 0
        var minimumAvailable: UInt64?
        var warnings = 0, thermal = 0
    }
    private let state = Mutex(State())
    private let started = clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)
    private let timer: DispatchSourceTimer
    private var warning: (any NSObjectProtocol)?
    public init() {
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "io.codemyriad.cassini.whistle.memory"))
        sample(baseline: true)
        warning = NotificationCenter.default.addObserver(forName: .init("UIApplicationDidReceiveMemoryWarningNotification"),
                                                         object: nil, queue: nil) { [weak self] _ in
            self?.state.withLock { $0.warnings += 1 }
        }
        timer.setEventHandler { [weak self] in self?.sample() }
        // Sampling is the measurement itself, not a delay used to await a test or native operation.
        timer.schedule(deadline: .now(), repeating: .milliseconds(100))
        timer.resume()
    }
    deinit {
        timer.cancel()
        if let warning { NotificationCenter.default.removeObserver(warning) }
    }
    private func sample(baseline: Bool = false) {
        var vm = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &vm) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard status == KERN_SUCCESS else { return }
        #if os(iOS)
        let available = UInt64(os_proc_available_memory())
        #else
        let available: UInt64 = 0
        #endif
        let footprint = vm.phys_footprint, peak = UInt64(vm.ledger_phys_footprint_peak), resident = vm.resident_size_peak
        let thermal = ProcessInfo.processInfo.thermalState.rawValue
        state.withLock {
            if baseline { $0.baseline = footprint }
            $0.peakFootprint = max($0.peakFootprint, footprint, peak)
            $0.peakResident = max($0.peakResident, resident)
            if available > 0 { $0.minimumAvailable = min($0.minimumAvailable ?? available, available) }
            $0.thermal = max($0.thermal, thermal)
        }
    }
    public func finish(succeeded: Bool, nativeModelReleased: Bool, scope: String = "transcription-stage") -> WhistleMemoryReport {
        timer.cancel(); sample()
        return state.withLock {
            WhistleMemoryReport(scope: scope, jobKind: nil, physicalMemoryBytes: ProcessInfo.processInfo.physicalMemory,
                operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString,
                baselineFootprintBytes: $0.baseline, peakFootprintBytes: $0.peakFootprint,
                peakResidentBytes: $0.peakResident, minimumAvailableBytes: $0.minimumAvailable,
                memoryWarnings: $0.warnings, maximumThermalState: $0.thermal,
                elapsedMilliseconds: Int64((clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)-started)/1_000_000),
                succeeded: succeeded, nativeModelReleased: nativeModelReleased)
        }
    }
}
